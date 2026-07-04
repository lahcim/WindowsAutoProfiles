#requires -Version 5.1
# Author: Michal Zygmunt <lahcim@fajne.com>

$ErrorActionPreference = 'Stop'

$script:CaptureRoot = 'C:\WAPCapture'
$script:CaptureFilters = $null
$script:CaptureMinimumPowerShellVersion = [version]'5.1'

function Assert-CapturePowerShellVersion {
    param(
        [Parameter(Mandatory)][string] $CommandName,
        [version] $MinimumVersion = $script:CaptureMinimumPowerShellVersion
    )

    if ($PSVersionTable.PSVersion -lt $MinimumVersion) {
        throw "Capture command '$CommandName' requires PowerShell $MinimumVersion or newer. Current version is $($PSVersionTable.PSVersion)."
    }
}

function Test-CaptureAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-CaptureAdministrator {
    param(
        [Parameter(Mandatory)][string] $CommandName,
        [Parameter(Mandatory)][string] $ScriptPath
    )

    if (Test-CaptureAdministrator) { return }

    $exactCommand = "powershell.exe -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $sudo = Get-Command sudo.exe -ErrorAction SilentlyContinue
    if ($sudo) {
        Write-Warning "Capture command '$CommandName' requires administrator rights. Trying Windows sudo..."
        & $sudo.Source powershell.exe -ExecutionPolicy Bypass -File $ScriptPath
        exit $LASTEXITCODE
    }

    throw "Capture command '$CommandName' requires administrator rights. Windows sudo.exe was not found. Open an elevated PowerShell session and run: $exactCommand"
}

function Get-CaptureLocations {
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    [ordered]@{
        ProgramFiles = $env:ProgramFiles
        ProgramFilesX86 = $programFilesX86
        ProgramData = $env:ProgramData
        AppDataRoaming = [Environment]::GetFolderPath('ApplicationData')
        AppDataLocal = [Environment]::GetFolderPath('LocalApplicationData')
        UserStartMenu = [Environment]::GetFolderPath('StartMenu')
        CommonStartMenu = [Environment]::GetFolderPath('CommonStartMenu')
    }
}

function Get-CaptureCurrentUser {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    [pscustomobject]@{
        userName = $env:USERNAME
        domainName = $env:USERDOMAIN
        qualifiedName = $identity.Name
        sid = $identity.User.Value
        isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        profilePath = $env:USERPROFILE
        appDataRoaming = [Environment]::GetFolderPath('ApplicationData')
        appDataLocal = [Environment]::GetFolderPath('LocalApplicationData')
    }
}

function ConvertTo-CaptureJsonArray {
    param(
        [Parameter(Mandatory)] $Items,
        [int] $Depth = 8
    )

    $array = if ($Items -is [System.Collections.ArrayList]) { @($Items.ToArray()) } else { @($Items) }
    ConvertTo-Json -InputObject $array -Depth $Depth
}

function Read-CaptureJsonItems {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $data) { return @() }

    if ($data.PSObject.Properties['value'] -and
        $data.PSObject.Properties['Capacity'] -and
        $data.PSObject.Properties['Count']) {
        return @($data.value | Where-Object { $null -ne $_ })
    }

    return @($data | Where-Object { $null -ne $_ })
}

function Write-FileSnapshot {
    param([Parameter(Mandatory)][string] $Destination)

    $items = [System.Collections.ArrayList]::new()
    $locations = @((Get-CaptureLocations).GetEnumerator())
    for ($index = 0; $index -lt $locations.Count; $index++) {
        $entry = $locations[$index]
        $percent = [int](($index / [Math]::Max(1, $locations.Count)) * 100)
        Write-Progress -Id 2 -Activity 'Capturing filesystem metadata' `
            -Status "$($entry.Key): $($entry.Value)" -PercentComplete $percent
        try {
            if ([string]::IsNullOrWhiteSpace([string]$entry.Value) -or
                -not (Test-Path -LiteralPath $entry.Value)) {
                continue
            }

            Get-ChildItem -LiteralPath $entry.Value -Force -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [void]$items.Add([pscustomobject]@{
                        scope = $entry.Key
                        path = $_.FullName
                        itemType = if ($_.PSIsContainer) { 'Directory' } else { 'File' }
                        length = if ($_.PSIsContainer) { $null } else { $_.Length }
                        lastWriteUtc = $_.LastWriteTimeUtc.ToString('o')
                    })
                }
        }
        finally {
            if ($index -eq ($locations.Count - 1)) {
                Write-Progress -Id 2 -Activity 'Capturing filesystem metadata' -Completed
            }
        }
    }
    ConvertTo-CaptureJsonArray -Items $items -Depth 5 |
        Set-Content -LiteralPath (Join-Path $Destination 'files.json') -Encoding UTF8
}

function Write-RegistrySnapshot {
    param([Parameter(Mandatory)][string] $Destination)

    Write-Progress -Id 3 -Activity 'Exporting registry snapshots' -Status 'HKCU\Software' -PercentComplete 0
    & reg.exe export 'HKCU\Software' (Join-Path $Destination 'HKCU-Software.reg') /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to export HKCU\Software.' }
    Write-Progress -Id 3 -Activity 'Exporting registry snapshots' -Status 'HKLM\Software' -PercentComplete 50
    & reg.exe export 'HKLM\Software' (Join-Path $Destination 'HKLM-Software.reg') /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to export HKLM\Software.' }
    Write-Progress -Id 3 -Activity 'Exporting registry snapshots' -Completed
}

function Invoke-CaptureProcessWithTimeout {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $ArgumentList,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][string] $ErrorPath
    )

    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    if (Test-Path -LiteralPath $ErrorPath) { Remove-Item -LiteralPath $ErrorPath -Force }
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru `
        -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force
            throw "$FilePath timed out after $TimeoutSeconds seconds."
        }
        if ($process.ExitCode -ne 0) {
            $errorText = if (Test-Path -LiteralPath $ErrorPath) {
                (Get-Content -LiteralPath $ErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
            }
            else { '' }
            throw "$FilePath exited with code $($process.ExitCode). $errorText"
        }
        if (Test-Path -LiteralPath $OutputPath) {
            return Get-Content -LiteralPath $OutputPath -ErrorAction Stop
        }
        return @()
    }
    finally {
        if (Test-Path -LiteralPath $ErrorPath) { Remove-Item -LiteralPath $ErrorPath -Force -ErrorAction SilentlyContinue }
    }
}

function Write-SystemSnapshot {
    param([Parameter(Mandatory)][string] $Destination)

    Write-Progress -Id 4 -Activity 'Capturing services and scheduled tasks' -Status 'Collecting services' -PercentComplete 0
    $services = @()
    $cimError = $null
    for ($attempt = 1; $attempt -le 3 -and -not $services.Count; $attempt++) {
        try {
            Write-Progress -Id 4 -Activity 'Capturing services and scheduled tasks' `
                -Status "Collecting services with CIM (attempt $attempt of 3)" -PercentComplete 10
            $services = @(Get-CimInstance Win32_Service -ErrorAction Stop |
                Select-Object Name, DisplayName, State, StartMode, PathName)
        }
        catch {
            $cimError = $_.Exception.Message
            if ($attempt -lt 3) { Start-Sleep -Seconds 3 }
        }
    }
    if (-not $services.Count) {
        Write-Warning "CIM service inventory failed; using Get-Service fallback. $cimError"
        Write-Progress -Id 4 -Activity 'Capturing services and scheduled tasks' `
            -Status 'Collecting services with Get-Service fallback' -PercentComplete 25
        $services = @(Get-Service | ForEach-Object {
            $service = $_
            $registry = Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($service.Name)" -ErrorAction SilentlyContinue
            $startMode = switch ($registry.Start) {
                2 { 'Auto' }
                3 { 'Manual' }
                4 { 'Disabled' }
                default { 'Unknown' }
            }
            [pscustomobject]@{
                Name = $service.Name
                DisplayName = $service.DisplayName
                State = [string]$service.Status
                StartMode = $startMode
                PathName = $registry.ImagePath
            }
        })
    }
    ConvertTo-CaptureJsonArray -Items $services -Depth 5 |
        Set-Content -LiteralPath (Join-Path $Destination 'services.json') -Encoding UTF8

    Write-Progress -Id 4 -Activity 'Capturing services and scheduled tasks' -Status 'Collecting scheduled tasks' -PercentComplete 50
    $tasks = @()
    try {
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    taskName = $_.TaskName
                    taskPath = $_.TaskPath
                    state = [string]$_.State
                    actions = @($_.Actions | ForEach-Object {
                        [pscustomobject]@{
                            execute = $_.Execute
                            arguments = $_.Arguments
                            workingDirectory = $_.WorkingDirectory
                        }
                    })
                }
            })
        }
        else {
            throw 'Get-ScheduledTask is unavailable.'
        }
    }
    catch {
        Write-Warning "ScheduledTasks cmdlets failed; using schtasks.exe fallback. $($_.Exception.Message)"
        Write-Progress -Id 4 -Activity 'Capturing services and scheduled tasks' `
            -Status 'Collecting scheduled tasks with schtasks.exe fallback' -PercentComplete 75
        $schtasksOutput = Join-Path $Destination 'scheduled-tasks.schtasks.csv'
        $schtasksError = Join-Path $Destination 'scheduled-tasks.schtasks.err'
        try {
            $taskRows = @(Invoke-CaptureProcessWithTimeout -FilePath 'schtasks.exe' `
                -ArgumentList @('/Query', '/FO', 'CSV') `
                -TimeoutSeconds 30 `
                -OutputPath $schtasksOutput `
                -ErrorPath $schtasksError)
            $tasks = @($taskRows | ConvertFrom-Csv | ForEach-Object {
                $taskPath = [string]$_.TaskName
                $lastSlash = $taskPath.LastIndexOf('\')
                $taskName = if ($lastSlash -ge 0) { $taskPath.Substring($lastSlash + 1) } else { $taskPath }
                $parentPath = if ($lastSlash -ge 0) { $taskPath.Substring(0, $lastSlash + 1) } else { '' }
                [pscustomobject]@{
                    taskName = $taskName
                    taskPath = $parentPath
                    state = $_.Status
                    actions = @([pscustomobject]@{
                        execute = $null
                        arguments = $null
                        workingDirectory = $null
                    })
                }
            })
        }
        catch {
            Write-Warning "schtasks.exe fallback failed; writing an empty scheduled task snapshot. $($_.Exception.Message)"
            $tasks = @()
        }
        finally {
            if (Test-Path -LiteralPath $schtasksOutput) {
                Remove-Item -LiteralPath $schtasksOutput -Force -ErrorAction SilentlyContinue
            }
        }
    }
    ConvertTo-CaptureJsonArray -Items $tasks -Depth 8 |
        Set-Content -LiteralPath (Join-Path $Destination 'scheduled-tasks.json') -Encoding UTF8
    Write-Progress -Id 4 -Activity 'Capturing services and scheduled tasks' -Completed
}
function Write-CaptureSnapshot {
    param([Parameter(Mandatory)][string] $Destination)

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    try {
        Write-Progress -Id 1 -Activity 'WindowsAutoProfiles capture snapshot' -Status 'Recording filesystem metadata' -PercentComplete 0
        Write-Host "Recording filesystem metadata..."
        Write-FileSnapshot -Destination $Destination
        Write-Progress -Id 1 -Activity 'WindowsAutoProfiles capture snapshot' -Status 'Exporting registry' -PercentComplete 35
        Write-Host "Exporting registry..."
        Write-RegistrySnapshot -Destination $Destination
        Write-Progress -Id 1 -Activity 'WindowsAutoProfiles capture snapshot' -Status 'Recording services and scheduled tasks' -PercentComplete 70
        Write-Host "Recording services and scheduled tasks..."
        Write-SystemSnapshot -Destination $Destination
        Write-Progress -Id 1 -Activity 'WindowsAutoProfiles capture snapshot' -Status 'Writing snapshot metadata' -PercentComplete 95
        [pscustomobject]@{
            capturedAt = (Get-Date).ToUniversalTime().ToString('o')
            computerName = $env:COMPUTERNAME
            currentUser = Get-CaptureCurrentUser
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'snapshot.json') -Encoding UTF8
    }
    finally {
        Write-Progress -Id 1 -Activity 'WindowsAutoProfiles capture snapshot' -Completed
        Write-Progress -Id 2 -Activity 'Capturing filesystem metadata' -Completed
        Write-Progress -Id 3 -Activity 'Exporting registry snapshots' -Completed
        Write-Progress -Id 4 -Activity 'Capturing services and scheduled tasks' -Completed
    }
}

function Get-RegistryBlocks {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Hive,
        [int] $ProgressId = 20,
        [int] $ParentProgressId = -1,
        [string] $Activity = 'Parsing registry snapshot'
    )

    $blocks = @{}
    $currentKey = $null
    $lines = [System.Collections.ArrayList]::new()
    $fileName = Split-Path -Leaf $Path
    $lastPercent = -1

    function Save-CurrentRegistryBlock {
        if (-not $currentKey) { return }
        $text = $lines -join "`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
        }
        finally {
            $sha.Dispose()
        }
        $storedLines = if ($currentKey -match '(?i)\\CurrentVersion\\Uninstall\\') { @($lines) } else { @() }
        $blocks["$Hive\$currentKey"] = [pscustomobject]@{
            hive = $Hive
            key = $currentKey
            hash = $hash
            lines = $storedLines
        }
    }

    $reader = New-Object System.IO.StreamReader -ArgumentList @($Path, $true)
    try {
        $length = $reader.BaseStream.Length
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($length -gt 0) {
                $percent = [Math]::Min(99, [int](($reader.BaseStream.Position / $length) * 100))
                if ($percent -ne $lastPercent) {
                    $progressParameters = @{
                        Id = $ProgressId
                        Activity = $Activity
                        Status = "${fileName}: $percent% ($($blocks.Count) keys)"
                        PercentComplete = $percent
                    }
                    if ($ParentProgressId -ge 0) { $progressParameters.ParentId = $ParentProgressId }
                    Write-Progress @progressParameters
                    $lastPercent = $percent
                }
            }

            if ($line -match '^\[(.+)\]$') {
                Save-CurrentRegistryBlock
                $currentKey = $Matches[1]
                $lines = [System.Collections.ArrayList]::new()
            }
            elseif ($currentKey -and -not [string]::IsNullOrWhiteSpace($line)) {
                [void]$lines.Add($line)
            }
        }
        Save-CurrentRegistryBlock
    }
    finally {
        $reader.Close()
        Write-Progress -Id $ProgressId -Activity $Activity -Completed
    }
    return $blocks
}

function Get-UninstallCommands {
    param([Parameter(Mandatory)] $RegistryBlocks)

    $commands = [System.Collections.ArrayList]::new()
    foreach ($block in $RegistryBlocks.Values) {
        if ($block.key -notmatch '(?i)\\CurrentVersion\\Uninstall\\') { continue }
        foreach ($line in $block.lines) {
            if ($line -match '^"(QuietUninstallString|UninstallString)"="(.*)"$') {
                $command = $Matches[2].Replace('\"', '"')
                [void]$commands.Add([pscustomobject]@{
                    source = 'registry'
                    registryKey = $block.key
                    command = $command
                })
            }
        }
    }
    return @($commands)
}

function Get-CaptureFilters {
    if ($script:CaptureFilters) { return $script:CaptureFilters }

    $candidatePaths = @(
        (Join-Path $script:CaptureRoot 'capture-filters.json'),
        (Join-Path $PSScriptRoot 'capture-filters.json')
    )
    $path = $null
    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $path = $candidatePath
            break
        }
    }
    if (-not $path) {
        throw "Capture filter file was not found. Checked: $($candidatePaths -join ', ')."
    }
    try {
        $script:CaptureFilters = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Capture filter file '$path' is invalid: $($_.Exception.Message)"
    }
    return $script:CaptureFilters
}

function Get-CaptureNoiseReason {
    param(
        [Parameter(Mandatory)] $Rules,
        [Parameter(Mandatory)][string] $Value
    )

    foreach ($rule in @($Rules)) {
        if ($Value -match ([string]$rule.pattern)) { return [string]$rule.reason }
    }
    return $null
}

function Get-CaptureRegistryNoiseReason {
    param([Parameter(Mandatory)] $RegistryChange)

    $key = [string]$RegistryChange.key
    return Get-CaptureNoiseReason -Rules (Get-CaptureFilters).registry -Value $key
}

function Get-CaptureFileNoiseReason {
    param([Parameter(Mandatory)] $FileChange)

    $path = [string]$FileChange.path
    return Get-CaptureNoiseReason -Rules (Get-CaptureFilters).file -Value $path
}

function Get-CaptureUninstallCommandNoiseReason {
    param([Parameter(Mandatory)] $UninstallCommand)

    $command = [string]$UninstallCommand.command
    $path = [string]$UninstallCommand.path
    $registryKey = [string]$UninstallCommand.registryKey

    foreach ($rule in @((Get-CaptureFilters).uninstall)) {
        if (($rule.PSObject.Properties['commandPattern'] -and $command -match ([string]$rule.commandPattern)) -or
            ($rule.PSObject.Properties['pathPattern'] -and $path -match ([string]$rule.pathPattern)) -or
            ($rule.PSObject.Properties['registryKeyPattern'] -and $registryKey -match ([string]$rule.registryKeyPattern))) {
            return [string]$rule.reason
        }
    }

    return $null
}
