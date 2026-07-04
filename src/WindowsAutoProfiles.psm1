#requires -Version 5.1
# Author: Michal Zygmunt <lahcim@fajne.com>

Set-StrictMode -Version Latest

$script:WapMinimumPowerShellVersion = [version]'5.1'
$script:WapVersion = '1.1'
$script:WapLastUpdated = '2026-07-04T05:18:20Z'

function Assert-WapPowerShellVersion {
    param(
        [Parameter(Mandatory)][string] $CommandName,
        [version] $MinimumVersion = $script:WapMinimumPowerShellVersion
    )

    if ($PSVersionTable.PSVersion -lt $MinimumVersion) {
        throw "Command '$CommandName' requires PowerShell $MinimumVersion or newer. Current version is $($PSVersionTable.PSVersion)."
    }
}

function ConvertFrom-WapConfigBoolean {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Value
    )

    switch ($Value.Trim().ToLowerInvariant()) {
        'true' { return $true }
        'false' { return $false }
        '1' { return $true }
        '0' { return $false }
        'yes' { return $true }
        'no' { return $false }
        default { throw "Configuration key '$Name' expects a boolean value: true or false." }
    }
}

function Expand-WapConfigValue {
    param([AllowNull()][string] $Value)

    if ($null -eq $Value) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    $expanded = [regex]::Replace($expanded, '\$\{env:([^}]+)\}', {
        param($match)
        $envValue = [Environment]::GetEnvironmentVariable($match.Groups[1].Value)
        if ($null -eq $envValue) { return $match.Value }
        return $envValue
    }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $expanded = [regex]::Replace($expanded, '\$env:([A-Za-z_][A-Za-z0-9_]*)', {
        param($match)
        $envValue = [Environment]::GetEnvironmentVariable($match.Groups[1].Value)
        if ($null -eq $envValue) { return $match.Value }
        return $envValue
    }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $expanded
}

function ConvertTo-WapOrderedHashtable {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[$key] = ConvertTo-WapOrderedHashtable $Value[$key]
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-WapOrderedHashtable $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return ,@($Value | ForEach-Object { ConvertTo-WapOrderedHashtable $_ })
    }
    return $Value
}

function ConvertFrom-WapEnabledValue {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $true }
    if ($Value -is [bool]) { return [bool]$Value }
    switch (([string]$Value).Trim().ToLowerInvariant()) {
        'true' { return $true }
        'false' { return $false }
        '1' { return $true }
        '0' { return $false }
        'yes' { return $true }
        'no' { return $false }
        default { throw "enabled expects a boolean value: true or false." }
    }
}

function Resolve-WapConfigPathValue {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $BasePath,
        [Parameter(Mandatory)][string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name cannot be empty."
    }

    $expanded = Expand-WapConfigValue $Value.Trim()
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $BasePath $expanded
    }
    return [IO.Path]::GetFullPath($expanded).TrimEnd([char[]]@('\', '/'))
}

function New-WapDefaultFullConfig {
    [pscustomobject]@{
        version = 1
        workspaceRoot = '%USERPROFILE%\Workspaces'
        profilesRoot = 'profiles'
        logging = [pscustomobject]@{
            enabled = $true
            retentionDays = 30
            root = '.logs'
        }
        sandbox = [pscustomobject]@{
            installWinget = $true
        }
    }
}

function Merge-WapConfigWithDefaults {
    param([AllowNull()][pscustomobject] $Config)

    $defaults = New-WapDefaultFullConfig
    if (-not $Config) { return $defaults }

    if (-not $Config.PSObject.Properties['version']) {
        Add-Member -InputObject $Config -MemberType NoteProperty -Name version -Value $defaults.version
    }
    if (-not $Config.PSObject.Properties['workspaceRoot']) {
        Add-Member -InputObject $Config -MemberType NoteProperty -Name workspaceRoot -Value $defaults.workspaceRoot
    }
    if (-not $Config.PSObject.Properties['profilesRoot']) {
        Add-Member -InputObject $Config -MemberType NoteProperty -Name profilesRoot -Value $defaults.profilesRoot
    }

    if (-not $Config.PSObject.Properties['logging'] -or -not $Config.logging) {
        Add-Member -InputObject $Config -MemberType NoteProperty -Name logging -Value ([pscustomobject]@{})
    }
    if (-not $Config.logging.PSObject.Properties['enabled']) {
        Add-Member -InputObject $Config.logging -MemberType NoteProperty -Name enabled -Value $defaults.logging.enabled
    }
    if (-not $Config.logging.PSObject.Properties['retentionDays']) {
        Add-Member -InputObject $Config.logging -MemberType NoteProperty -Name retentionDays -Value $defaults.logging.retentionDays
    }
    if (-not $Config.logging.PSObject.Properties['root']) {
        Add-Member -InputObject $Config.logging -MemberType NoteProperty -Name root -Value $defaults.logging.root
    }

    if (-not $Config.PSObject.Properties['sandbox'] -or -not $Config.sandbox) {
        Add-Member -InputObject $Config -MemberType NoteProperty -Name sandbox -Value ([pscustomobject]@{})
    }
    if (-not $Config.sandbox.PSObject.Properties['installWinget']) {
        Add-Member -InputObject $Config.sandbox -MemberType NoteProperty -Name installWinget -Value $defaults.sandbox.installWinget
    }

    return $Config
}

function Get-WapConfigPaths {
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $localBootstrapPath = Join-Path $RepositoryRoot 'wap.config.json'
    if (-not (Test-Path -LiteralPath $localBootstrapPath -PathType Leaf)) {
        return [pscustomobject]@{
            localBootstrapPath = $localBootstrapPath
            bootstrapPath = $localBootstrapPath
            fullConfigPath = $localBootstrapPath
            mode = 'missing'
        }
    }

    try {
        $localBootstrap = Get-Content -LiteralPath $localBootstrapPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Configuration file '$localBootstrapPath' is invalid: $($_.Exception.Message)"
    }

    $bootstrap = $localBootstrap
    $bootstrapPath = $localBootstrapPath
    if ($localBootstrap.PSObject.Properties['bootstrapConfigPath'] -and
        -not [string]::IsNullOrWhiteSpace([string]$localBootstrap.bootstrapConfigPath)) {
        $bootstrapPath = Resolve-WapConfigPathValue -Value ([string]$localBootstrap.bootstrapConfigPath) -BasePath $RepositoryRoot -Name 'bootstrapConfigPath'
        if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
            return [pscustomobject]@{
                localBootstrapPath = $localBootstrapPath
                bootstrapPath = $bootstrapPath
                fullConfigPath = $bootstrapPath
                mode = 'missingBootstrap'
                localBootstrap = $localBootstrap
            }
        }
        try {
            $bootstrap = Get-Content -LiteralPath $bootstrapPath -Raw | ConvertFrom-Json
        }
        catch {
            throw "Bootstrap configuration file '$bootstrapPath' is invalid: $($_.Exception.Message)"
        }
    }

    if ($bootstrap.PSObject.Properties['configPath'] -and
        -not [string]::IsNullOrWhiteSpace([string]$bootstrap.configPath)) {
        $bootstrapDirectory = Split-Path -Parent $bootstrapPath
        $fullConfigPath = Resolve-WapConfigPathValue -Value ([string]$bootstrap.configPath) -BasePath $bootstrapDirectory -Name 'configPath'
        return [pscustomobject]@{
            localBootstrapPath = $localBootstrapPath
            bootstrapPath = $bootstrapPath
            fullConfigPath = $fullConfigPath
            mode = 'external'
            localBootstrap = $localBootstrap
            bootstrap = $bootstrap
        }
    }

    [pscustomobject]@{
        localBootstrapPath = $localBootstrapPath
        bootstrapPath = $bootstrapPath
        fullConfigPath = $bootstrapPath
        mode = 'inline'
        localBootstrap = $localBootstrap
        bootstrap = $bootstrap
    }
}

function Get-WapRawConfig {
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $paths = Get-WapConfigPaths -RepositoryRoot $RepositoryRoot
    $path = $paths.fullConfigPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return New-WapDefaultFullConfig
    }

    try {
        return Merge-WapConfigWithDefaults (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    }
    catch {
        throw "Configuration file '$path' is invalid: $($_.Exception.Message)"
    }
}

function Get-WapLogConfig {
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $raw = Get-WapRawConfig -RepositoryRoot $RepositoryRoot
    $enabled = $true
    $retentionDays = 30
    if ($raw.PSObject.Properties['logging'] -and $raw.logging) {
        if ($raw.logging.PSObject.Properties['enabled']) {
            if ($raw.logging.enabled -is [bool]) {
                $enabled = [bool]$raw.logging.enabled
            }
            else {
                $enabled = ConvertFrom-WapConfigBoolean -Name 'logging.enabled' -Value ([string]$raw.logging.enabled)
            }
        }
        if ($raw.logging.PSObject.Properties['retentionDays']) {
            $retentionDays = [int]$raw.logging.retentionDays
        }
    }
    if ($retentionDays -lt 0) {
        throw 'logging.retentionDays cannot be negative. Use 0 to disable automatic log deletion.'
    }

    $rootValue = '.logs'
    if ($raw.PSObject.Properties['logging'] -and $raw.logging -and
        $raw.logging.PSObject.Properties['root'] -and
        -not [string]::IsNullOrWhiteSpace([string]$raw.logging.root)) {
        $rootValue = [string]$raw.logging.root
    }
    $logRoot = Resolve-WapConfigPathValue -Value $rootValue -BasePath $RepositoryRoot -Name 'logging.root'

    [pscustomobject]@{
        enabled = $enabled
        retentionDays = $retentionDays
        root = $logRoot
        rawRoot = $rootValue
    }
}

function Get-WapSafeLogName {
    param([AllowNull()][string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return 'help' }
    $safe = $Value -replace '[^A-Za-z0-9._-]+', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'command' }
    return $safe
}

function Start-WapCommandLog {
    param(
        [AllowNull()][string] $Command,
        [string[]] $Arguments,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [switch] $Disabled
    )

    if ($Disabled) { return $null }
    try {
        $config = Get-WapLogConfig -RepositoryRoot $RepositoryRoot
    }
    catch {
        $config = [pscustomobject]@{
            enabled = $true
            retentionDays = 30
            root = Join-Path $RepositoryRoot '.logs'
        }
        Write-Warning "Could not read logging configuration; using default logging. $($_.Exception.Message)"
    }
    if (-not $config.enabled) { return $null }

    New-Item -ItemType Directory -Path $config.root -Force | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $commandName = Get-WapSafeLogName $Command
    $fileName = "$timestamp-$commandName-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"
    $path = Join-Path $config.root $fileName
    Start-Transcript -LiteralPath $path -Force | Out-Null
    Write-Host "WindowsAutoProfiles command log"
    Write-Host "Version: $script:WapVersion"
    Write-Host "Last updated: $script:WapLastUpdated"
    Write-Host "Started UTC: $((Get-Date).ToUniversalTime().ToString('o'))"
    Write-Host "Repository: $RepositoryRoot"
    $commandParts = @()
    if (-not [string]::IsNullOrWhiteSpace($Command)) { $commandParts += $Command }
    $commandParts += @($Arguments | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
    Write-Host "Command: .\wap.ps1 $(ConvertTo-WapCommandLine -Arguments $commandParts)"
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "OS: $([Environment]::OSVersion.VersionString)"
    Write-Host ''
    return [pscustomobject]@{
        path = $path
        retentionDays = $config.retentionDays
        root = $config.root
    }
}

function Stop-WapCommandLog {
    param($Log)

    if (-not $Log) { return }
    Write-Host ''
    Write-Host "Detailed log file: $($Log.path)"
    try { Stop-Transcript | Out-Null }
    catch { Write-Warning "Could not stop command transcript: $($_.Exception.Message)" }
}

function Invoke-WapLogRetentionCleanup {
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $Root,
        [AllowNull()] $RetentionDays
    )

    $config = Get-WapLogConfig -RepositoryRoot $RepositoryRoot
    $cleanupRoot = if ([string]::IsNullOrWhiteSpace($Root)) { $config.root } else { $Root }
    $cleanupRetentionDays = if ($null -ne $RetentionDays) { [int]$RetentionDays } else { $config.retentionDays }
    if ($cleanupRetentionDays -eq 0) { return }
    if (-not (Test-Path -LiteralPath $cleanupRoot -PathType Container)) { return }
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * $cleanupRetentionDays)
    Get-ChildItem -LiteralPath $cleanupRoot -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Continue
        }
}

function Remove-WapLogs {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $config = Get-WapLogConfig -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $config.root -PathType Container)) {
        Write-Host "No log directory found at '$($config.root)'."
        return
    }

    $currentLog = [Environment]::GetEnvironmentVariable('WAP_CURRENT_LOG_PATH', 'Process')
    $logs = @(
        Get-ChildItem -LiteralPath $config.root -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { -not $currentLog -or -not [string]::Equals($_.FullName, $currentLog, [StringComparison]::OrdinalIgnoreCase) }
    )
    Write-Host "Deleting $($logs.Count) generated log file(s) from '$($config.root)'."
    foreach ($log in $logs) {
        Write-Host "  [delete] $($log.FullName)"
        if ($PSCmdlet.ShouldProcess($log.FullName, 'Delete generated log file')) {
            Remove-Item -LiteralPath $log.FullName -Force
        }
    }
    if ($currentLog) {
        Write-Host "  [keep] Current command log '$currentLog'"
    }
}

function Test-WapAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WapWingetAvailable {
    return $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
}

function Install-WapWingetFromLocalPackages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $PrereqRoot)

    $vclibs = Join-Path $PrereqRoot 'Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx'
    $vclibsDesktop = Join-Path $PrereqRoot 'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx'
    $windowsAppRuntime = Join-Path $PrereqRoot 'Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64.appx'
    $appInstaller = Join-Path $PrereqRoot 'Microsoft.DesktopAppInstaller.msixbundle'
    foreach ($package in @($vclibs, $vclibsDesktop, $windowsAppRuntime, $appInstaller)) {
        if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
            throw "Required winget prerequisite package was not found: $package"
        }
    }

    Write-Host "  [install] Installing winget from local package prerequisites at '$PrereqRoot'..."
    Add-AppxPackage -Path $vclibs
    Add-AppxPackage -Path $vclibsDesktop
    Add-AppxPackage -Path $windowsAppRuntime
    Add-AppxPackage -Path $appInstaller -DependencyPath @($vclibs, $vclibsDesktop, $windowsAppRuntime)
}

function Install-WapWingetPrerequisite {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Host 'Checking prerequisite: winget'
    if (Test-WapWingetAvailable) {
        Write-Host '  [ok] winget is already available.'
        return
    }

    Write-Host '  [missing] winget was not found.'
    if ($WhatIfPreference) {
        if ($PSCmdlet.ShouldProcess('winget', 'Install Windows Package Manager prerequisite')) { }
        Write-Host '  [whatif] winget would be installed if this command was run without -WhatIf.'
        return
    }

    Write-Host '  [install] Trying to register Microsoft App Installer for the current user...'
    if ($PSCmdlet.ShouldProcess('Microsoft.DesktopAppInstaller_8wekyb3d8bbwe', 'Register App Installer package')) {
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
        }
        catch {
            Write-Warning "App Installer registration did not complete: $($_.Exception.Message)"
        }
    }

    if (Test-WapWingetAvailable) {
        Write-Host '  [ok] winget is now available.'
        return
    }

    $localPrereqRoot = [Environment]::GetEnvironmentVariable('WAP_WINGET_PREREQ_ROOT', 'Process')
    if ($localPrereqRoot) {
        if ($PSCmdlet.ShouldProcess($localPrereqRoot, 'Install Windows Package Manager from local packages')) {
            Install-WapWingetFromLocalPackages -PrereqRoot $localPrereqRoot
        }
        if (Test-WapWingetAvailable) {
            Write-Host '  [ok] winget is now available.'
            return
        }
    }

    Write-Host '  [install] Trying Microsoft.WinGet.Client Repair-WinGetPackageManager fallback...'
    if ($PSCmdlet.ShouldProcess('winget', 'Install Windows Package Manager via Microsoft.WinGet.Client')) {
        try {
            Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope CurrentUser -AllowClobber -ErrorAction Stop | Out-Null
            Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop
            if (Test-WapAdministrator) {
                Repair-WinGetPackageManager -AllUsers -ErrorAction Stop
            }
            else {
                Repair-WinGetPackageManager -ErrorAction Stop
            }
        }
        catch {
            throw "winget was not found and automatic installation failed. Install App Installer from https://apps.microsoft.com/detail/9nblggh4nns1 or rerun '.\wap.ps1 init' from an elevated PowerShell session. Details: $($_.Exception.Message)"
        }
    }

    if (-not (Test-WapWingetAvailable)) {
        throw "winget installation completed, but winget is still not available on PATH. Open a new terminal and run '.\wap.ps1 init' again, or install App Installer from https://apps.microsoft.com/detail/9nblggh4nns1."
    }

    Write-Host '  [ok] winget is now available.'
}

function Install-WapPrerequisites {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Host 'Installing WindowsAutoProfiles prerequisites...'
    Install-WapWingetPrerequisite -WhatIf:$WhatIfPreference
    Write-Host 'Done: prerequisites are installed.'
}

function ConvertTo-WapCommandLine {
    param([AllowEmptyCollection()][string[]] $Arguments)

    return ((@($Arguments) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_.Replace('"', '\"')) + '"' } else { $_ }
    }) -join ' ')
}

function Invoke-WapElevatedCommandOrThrow {
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Reason
    )

    if (Test-WapAdministrator) { return }

    $scriptPath = Join-Path $RepositoryRoot 'wap.ps1'
    $exactArguments = @('-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $Arguments
    $exactCommand = "powershell.exe $(ConvertTo-WapCommandLine -Arguments $exactArguments)"
    $sudo = Get-Command sudo.exe -ErrorAction SilentlyContinue
    if ($sudo) {
        Write-Warning "$Reason Trying Windows sudo..."
        & $sudo.Source powershell.exe @exactArguments
        exit $LASTEXITCODE
    }

    throw "$Reason Windows sudo.exe was not found. Open an elevated PowerShell session and run: $exactCommand"
}

function ConvertFrom-WapScalar {
    param([string] $Value)

    $value = $Value.Trim()
    if ($value -in @('', 'null', '~')) { return $null }
    if ($value -match '^(true|false)$') { return [bool]::Parse($value) }
    if ($value -match '^-?\d+$') { return [long]$value }
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        return $value.Substring(1, $value.Length - 2)
    }
    if ($value.StartsWith('[') -and $value.EndsWith(']')) {
        $inner = $value.Substring(1, $value.Length - 2)
        if ([string]::IsNullOrWhiteSpace($inner)) { return @() }
        return @($inner -split ',' | ForEach-Object { ConvertFrom-WapScalar $_ })
    }
    return $value
}

function Remove-WapYamlComment {
    param([string] $Line)

    $single = $false
    $double = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        switch ($Line[$i]) {
            "'" { if (-not $double) { $single = -not $single } }
            '"' { if (-not $single) { $double = -not $double } }
            '#' {
                if (-not $single -and -not $double -and
                    ($i -eq 0 -or [char]::IsWhiteSpace($Line[$i - 1]))) {
                    return $Line.Substring(0, $i).TrimEnd()
                }
            }
        }
    }
    return $Line.TrimEnd()
}

function ConvertFrom-WapSimpleYaml {
    <#
      Parses the intentionally small profile schema without requiring a gallery
      module. Supported constructs: top-level scalars, nested maps, scalar lists,
      and lists of one-level maps.
    #>
    param([Parameter(Mandatory)][string] $Yaml)

    $result = [ordered]@{}
    $section = $null
    $currentListItem = $null

    foreach ($rawLine in ($Yaml -split "`r?`n")) {
        $line = Remove-WapYamlComment $rawLine
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('---')) {
            continue
        }

        $indent = $line.Length - $line.TrimStart().Length
        $text = $line.Trim()

        if ($indent -eq 0) {
            if ($text -notmatch '^([A-Za-z][A-Za-z0-9_-]*):(?:\s*(.*))?$') {
                throw "Unsupported YAML near '$text'."
            }
            $key = $Matches[1]
            $value = $Matches[2]
            $currentListItem = $null
            if ([string]::IsNullOrWhiteSpace($value)) {
                $result[$key] = $null
                $section = $key
            }
            else {
                $result[$key] = ConvertFrom-WapScalar $value
                $section = $null
            }
            continue
        }

        if (-not $section) { throw "Unexpected indentation near '$text'." }

        if ($text.StartsWith('- ')) {
            if ($null -eq $result[$section]) {
                $result[$section] = [System.Collections.ArrayList]::new()
            }
            if ($result[$section] -isnot [System.Collections.IList]) {
                throw "Cannot mix a map and list in '$section'."
            }
            $itemText = $text.Substring(2).Trim()
            if ($itemText -match '^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$') {
                $currentListItem = [ordered]@{
                    $Matches[1] = ConvertFrom-WapScalar $Matches[2]
                }
                [void]$result[$section].Add($currentListItem)
            }
            else {
                [void]$result[$section].Add((ConvertFrom-WapScalar $itemText))
                $currentListItem = $null
            }
            continue
        }

        if ($text -match '^([A-Za-z][A-Za-z0-9_.-]*):\s*(.*)$') {
            $key = $Matches[1]
            $value = ConvertFrom-WapScalar $Matches[2]
            if ($currentListItem -and $indent -ge 4) {
                $currentListItem[$key] = $value
            }
            else {
                if ($null -eq $result[$section]) {
                    $result[$section] = [ordered]@{}
                }
                if ($result[$section] -isnot [System.Collections.IDictionary]) {
                    throw "Cannot mix a map and list in '$section'."
                }
                $result[$section][$key] = $value
            }
            continue
        }

        throw "Unsupported YAML near '$text'."
    }

    return [pscustomobject]$result
}

function Get-WapConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $paths = Get-WapConfigPaths -RepositoryRoot $RepositoryRoot
    if ($paths.mode -eq 'missing') {
        throw "Configuration was not found at '$($paths.bootstrapPath)'. Run '.\wap.ps1 init'."
    }
    if ($paths.mode -eq 'missingBootstrap') {
        throw "Bootstrap configuration was not found at '$($paths.bootstrapPath)'. Run '.\wap.ps1 config set bootstrapConfigPath <path>' or update '$($paths.localBootstrapPath)'."
    }
    if (-not (Test-Path -LiteralPath $paths.fullConfigPath -PathType Leaf)) {
        throw "Full configuration was not found at '$($paths.fullConfigPath)'. Run '.\wap.ps1 init' or update configPath."
    }

    $config = Get-WapRawConfig -RepositoryRoot $RepositoryRoot

    if ($config.version -ne 1) {
        throw "Unsupported or missing configuration version. Expected version 1."
    }
    if (-not $config.PSObject.Properties['workspaceRoot'] -or
        [string]::IsNullOrWhiteSpace([string]$config.workspaceRoot)) {
        throw "Configuration file '$($paths.fullConfigPath)' must define workspaceRoot."
    }

    $workspaceRoot = Expand-WapConfigValue ([string]$config.workspaceRoot)
    if (-not [IO.Path]::IsPathRooted($workspaceRoot)) {
        throw "workspaceRoot must resolve to an absolute path. Resolved value: '$workspaceRoot'."
    }

    $configDirectory = Split-Path -Parent $paths.fullConfigPath
    $profilesRootValue = if ($config.PSObject.Properties['profilesRoot'] -and
        -not [string]::IsNullOrWhiteSpace([string]$config.profilesRoot)) {
        [string]$config.profilesRoot
    }
    else {
        'profiles'
    }
    $profilesRoot = Resolve-WapConfigPathValue -Value $profilesRootValue -BasePath $configDirectory -Name 'profilesRoot'

    $logConfig = Get-WapLogConfig -RepositoryRoot $RepositoryRoot
    $sandboxInstallWinget = $true
    if ($config.PSObject.Properties['sandbox'] -and $config.sandbox -and $config.sandbox.PSObject.Properties['installWinget']) {
        if ($config.sandbox.installWinget -is [bool]) {
            $sandboxInstallWinget = [bool]$config.sandbox.installWinget
        }
        else {
            $sandboxInstallWinget = ConvertFrom-WapConfigBoolean -Name 'sandbox.installWinget' -Value ([string]$config.sandbox.installWinget)
        }
    }
    [pscustomobject]@{
        version = 1
        workspaceRoot = ([IO.Path]::GetFullPath($workspaceRoot)).TrimEnd([char[]]@('\', '/'))
        profilesRoot = $profilesRoot
        loggingEnabled = $logConfig.enabled
        loggingRetentionDays = $logConfig.retentionDays
        logRoot = $logConfig.root
        sandboxInstallWinget = $sandboxInstallWinget
        source = $paths.fullConfigPath
        bootstrap = $paths.bootstrapPath
        localBootstrap = $paths.localBootstrapPath
        mode = $paths.mode
    }
}
function Show-WapConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $raw = Merge-WapConfigWithDefaults (Get-Content -LiteralPath $config.source -Raw | ConvertFrom-Json)
    $bootstrap = Get-Content -LiteralPath $config.bootstrap -Raw | ConvertFrom-Json
    $localBootstrap = Get-Content -LiteralPath $config.localBootstrap -Raw | ConvertFrom-Json
    $rawBootstrapConfigPath = if ($localBootstrap.PSObject.Properties['bootstrapConfigPath']) { [string]$localBootstrap.bootstrapConfigPath } else { '<local wap.config.json>' }
    $rawProfilesRoot = if ($raw.PSObject.Properties['profilesRoot']) { [string]$raw.profilesRoot } else { 'profiles' }
    $rawConfigPath = if ($bootstrap.PSObject.Properties['configPath']) { [string]$bootstrap.configPath } else { '<inline>' }
    $rawLoggingRoot = if ($raw.PSObject.Properties['logging'] -and $raw.logging -and $raw.logging.PSObject.Properties['root']) { [string]$raw.logging.root } else { '.logs' }
    $rawSandboxInstallWinget = if ($raw.PSObject.Properties['sandbox'] -and $raw.sandbox -and $raw.sandbox.PSObject.Properties['installWinget']) { $raw.sandbox.installWinget } else { $true }

    Write-Output 'Configurable settings (use ".\wap.ps1 config set <key> <value>" on these keys only):'
    [pscustomobject]@{
        version = $config.version
        bootstrapConfigPath = $rawBootstrapConfigPath
        configPath = $rawConfigPath
        workspaceRoot = [string]$raw.workspaceRoot
        profilesRoot = $rawProfilesRoot
        'logging.enabled' = $config.loggingEnabled
        'logging.retentionDays' = $config.loggingRetentionDays
        'logging.root' = $rawLoggingRoot
        'sandbox.installWinget' = $rawSandboxInstallWinget
    } | Format-List | Out-String -Width 4096
    Write-Output ''
    Write-Output 'Dynamic resolved settings (read-only; computed at runtime from the configurable settings above):'
    [pscustomobject]@{
        'local.bootstrapConfigPath' = $config.localBootstrap
        'resolved.bootstrapConfigPath' = $config.bootstrap
        'resolved.configPath' = $config.source
        'resolved.workspaceRoot' = $config.workspaceRoot
        'resolved.profilesRoot' = $config.profilesRoot
        'resolved.logging.root' = $config.logRoot
    } | Format-List | Out-String -Width 4096
}

function Set-WapConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $paths = Get-WapConfigPaths -RepositoryRoot $RepositoryRoot
    $path = if ($Key -eq 'bootstrapConfigPath') { $paths.localBootstrapPath } elseif ($Key -eq 'configPath') { $paths.bootstrapPath } else { $paths.fullConfigPath }
    $raw = Get-WapRawConfig -RepositoryRoot $RepositoryRoot
    $storedValue = $Value.Trim()
    $resolvedValue = $null
    if (-not $raw.PSObject.Properties['logging'] -or -not $raw.logging) {
        Add-Member -InputObject $raw -MemberType NoteProperty -Name logging -Value ([pscustomobject]@{
            enabled = $true
            retentionDays = 30
        })
    }
    if (-not $raw.logging.PSObject.Properties['enabled']) {
        Add-Member -InputObject $raw.logging -MemberType NoteProperty -Name enabled -Value $true
    }
    if (-not $raw.logging.PSObject.Properties['retentionDays']) {
        Add-Member -InputObject $raw.logging -MemberType NoteProperty -Name retentionDays -Value 30
    }
    if (-not $raw.PSObject.Properties['sandbox'] -or -not $raw.sandbox) {
        Add-Member -InputObject $raw -MemberType NoteProperty -Name sandbox -Value ([pscustomobject]@{
            installWinget = $true
        })
    }
    if (-not $raw.sandbox.PSObject.Properties['installWinget']) {
        Add-Member -InputObject $raw.sandbox -MemberType NoteProperty -Name installWinget -Value $true
    }

    switch ($Key) {
        'bootstrapConfigPath' {
            if ([string]::IsNullOrWhiteSpace($Value)) {
                throw 'bootstrapConfigPath cannot be empty.'
            }
            $localBootstrap = if (Test-Path -LiteralPath $paths.localBootstrapPath -PathType Leaf) {
                Get-Content -LiteralPath $paths.localBootstrapPath -Raw | ConvertFrom-Json
            }
            else {
                [pscustomobject]@{ version = 1 }
            }
            if (-not $localBootstrap.PSObject.Properties['version']) {
                Add-Member -InputObject $localBootstrap -MemberType NoteProperty -Name version -Value 1
            }
            $resolvedValue = Resolve-WapConfigPathValue -Value $storedValue -BasePath $RepositoryRoot -Name 'bootstrapConfigPath'
            if (-not $localBootstrap.PSObject.Properties['bootstrapConfigPath']) {
                Add-Member -InputObject $localBootstrap -MemberType NoteProperty -Name bootstrapConfigPath -Value $storedValue
            }
            else {
                $localBootstrap.bootstrapConfigPath = $storedValue
            }

            if (-not (Test-Path -LiteralPath $resolvedValue -PathType Leaf)) {
                $targetDirectory = Split-Path -Parent $resolvedValue
                if ($PSCmdlet.ShouldProcess($targetDirectory, 'Create bootstrap configuration directory')) {
                    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
                }
                $existingConfigPath = if ($paths.PSObject.Properties['bootstrap'] -and $paths.bootstrap -and
                    $paths.bootstrap.PSObject.Properties['configPath']) {
                    [string]$paths.bootstrap.configPath
                }
                else {
                    'wap.settings.json'
                }
                $bootstrapToWrite = [pscustomobject]@{
                    version = 1
                    configPath = $existingConfigPath
                }
                if ($PSCmdlet.ShouldProcess($resolvedValue, 'Create bootstrap configuration file')) {
                    $bootstrapToWrite | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedValue -Encoding utf8
                }
            }
            if ($PSCmdlet.ShouldProcess($paths.localBootstrapPath, "Set $Key to '$storedValue'")) {
                $temp = "$($paths.localBootstrapPath).tmp"
                $localBootstrap | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding utf8
                Move-Item -LiteralPath $temp -Destination $paths.localBootstrapPath -Force
            }
            if (-not $WhatIfPreference) {
                Write-Host "$Key set to '$storedValue'."
                Write-Host "Resolved bootstrap config path: $resolvedValue"
            }
            return
        }
        'configPath' {
            if ([string]::IsNullOrWhiteSpace($Value)) {
                throw 'configPath cannot be empty.'
            }
            $bootstrap = if (Test-Path -LiteralPath $paths.bootstrapPath -PathType Leaf) {
                Get-Content -LiteralPath $paths.bootstrapPath -Raw | ConvertFrom-Json
            }
            else {
                [pscustomobject]@{ version = 1 }
            }
            if (-not $bootstrap.PSObject.Properties['version']) {
                Add-Member -InputObject $bootstrap -MemberType NoteProperty -Name version -Value 1
            }
            $bootstrapDirectory = Split-Path -Parent $paths.bootstrapPath
            $resolvedValue = Resolve-WapConfigPathValue -Value $storedValue -BasePath $bootstrapDirectory -Name 'configPath'
            if (-not $bootstrap.PSObject.Properties['configPath']) {
                Add-Member -InputObject $bootstrap -MemberType NoteProperty -Name configPath -Value $storedValue
            }
            else {
                $bootstrap.configPath = $storedValue
            }
            if (-not (Test-Path -LiteralPath $resolvedValue -PathType Leaf)) {
                $targetDirectory = Split-Path -Parent $resolvedValue
                if ($PSCmdlet.ShouldProcess($targetDirectory, 'Create full configuration directory')) {
                    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
                }
                if ($PSCmdlet.ShouldProcess($resolvedValue, 'Create full configuration file')) {
                    $raw | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedValue -Encoding utf8
                }
            }
            if ($PSCmdlet.ShouldProcess($paths.bootstrapPath, "Set $Key to '$storedValue'")) {
                $temp = "$($paths.bootstrapPath).tmp"
                $bootstrap | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding utf8
                Move-Item -LiteralPath $temp -Destination $paths.bootstrapPath -Force
            }
            if (-not $WhatIfPreference) {
                Write-Host "$Key set to '$storedValue'."
                Write-Host "Resolved config path: $resolvedValue"
            }
            return
        }
        'workspaceRoot' {
            if ([string]::IsNullOrWhiteSpace($Value)) {
                throw 'workspaceRoot cannot be empty.'
            }
            $resolvedValue = Expand-WapConfigValue $storedValue
            if (-not [IO.Path]::IsPathRooted($resolvedValue)) {
                throw "workspaceRoot must resolve to an absolute path. Resolved value: '$resolvedValue'."
            }
            $raw.workspaceRoot = $storedValue
        }
        'profilesRoot' {
            $configDirectory = Split-Path -Parent $paths.fullConfigPath
            $resolvedValue = Resolve-WapConfigPathValue -Value $storedValue -BasePath $configDirectory -Name 'profilesRoot'
            if (-not $raw.PSObject.Properties['profilesRoot']) {
                Add-Member -InputObject $raw -MemberType NoteProperty -Name profilesRoot -Value $storedValue
            }
            else {
                $raw.profilesRoot = $storedValue
            }
        }
        'logging.enabled' {
            $raw.logging.enabled = ConvertFrom-WapConfigBoolean -Name $Key -Value $storedValue
        }
        'logging.retentionDays' {
            $days = 0
            if (-not [int]::TryParse($storedValue, [ref]$days) -or $days -lt 0) {
                throw 'logging.retentionDays must be a non-negative integer. Use 0 to disable automatic log deletion.'
            }
            $raw.logging.retentionDays = $days
        }
        'logging.root' {
            if ([string]::IsNullOrWhiteSpace($Value)) {
                throw 'logging.root cannot be empty.'
            }
            $resolvedValue = Resolve-WapConfigPathValue -Value $storedValue -BasePath $RepositoryRoot -Name 'logging.root'
            if (-not $raw.logging.PSObject.Properties['root']) {
                Add-Member -InputObject $raw.logging -MemberType NoteProperty -Name root -Value $storedValue
            }
            else {
                $raw.logging.root = $storedValue
            }
        }
        'sandbox.installWinget' {
            $raw.sandbox.installWinget = ConvertFrom-WapConfigBoolean -Name $Key -Value $storedValue
        }
        { $_ -in @('ResolvedConfigPath', 'ResolvedWorkspaceRoot', 'ResolvedProfilesRoot', 'ResolvedBootstrapConfigPath', 'LocalBootstrapConfigPath', 'ResolvedLoggingRoot', 'resolved.configPath', 'resolved.workspaceRoot', 'resolved.profilesRoot', 'resolved.bootstrapConfigPath', 'local.bootstrapConfigPath', 'resolved.logging.root') } {
            $targetKey = switch ($Key) {
                'ResolvedConfigPath' { 'configPath' }
                'ResolvedWorkspaceRoot' { 'workspaceRoot' }
                'ResolvedProfilesRoot' { 'profilesRoot' }
                'ResolvedBootstrapConfigPath' { 'bootstrapConfigPath' }
                'ResolvedLoggingRoot' { 'logging.root' }
                'resolved.configPath' { 'configPath' }
                'resolved.workspaceRoot' { 'workspaceRoot' }
                'resolved.profilesRoot' { 'profilesRoot' }
                'resolved.bootstrapConfigPath' { 'bootstrapConfigPath' }
                'resolved.logging.root' { 'logging.root' }
                default { $null }
            }
            if ($targetKey) {
                throw "Configuration key '$Key' is dynamic and read-only. Set '$targetKey' instead; WAP resolves '$Key' at runtime."
            }
            throw "Configuration key '$Key' is dynamic and read-only. It is shown by 'config show' for diagnostics and cannot be set."
        }
        { $_ -in @('LoggingRoot', 'loggingRoot', 'loggingroot') } {
            throw "Unknown configuration key '$Key'. Use 'logging.root' instead."
        }
        default {
            throw "Unknown configuration key '$Key'. Supported keys: bootstrapConfigPath, configPath, workspaceRoot, profilesRoot, logging.enabled, logging.retentionDays, logging.root, sandbox.installWinget."
        }
    }

    if ($PSCmdlet.ShouldProcess($path, "Set $Key to '$storedValue'")) {
        $temp = "$path.tmp"
        $raw | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $path -Force
    }

    if (-not $WhatIfPreference) {
        Write-Host "$Key set to '$storedValue'."
        if ($resolvedValue) {
            switch ($Key) {
                'workspaceRoot' { Write-Host "Resolved workspace root: $resolvedValue" }
                'profilesRoot' { Write-Host "Resolved profiles root: $resolvedValue" }
                'logging.root' {
                    Write-Host "Resolved logging root: $resolvedValue"
                    if (-not (Test-Path -LiteralPath $resolvedValue -PathType Container)) {
                        Write-Warning "Logging root does not exist yet. It will be created when logging starts on the next command."
                    }
                }
                default { Write-Host "Resolved value: $resolvedValue" }
            }
        }
    }
}
function Import-WapProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid profile name '$Name'. Use letters, numbers, dots, underscores, and hyphens."
    }

    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $path = Join-Path (Join-Path $config.profilesRoot $Name) 'profile.yaml'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Profile '$Name' was not found at '$path'."
    }

    $yaml = Get-Content -LiteralPath $path -Raw
    $yamlCommand = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($yamlCommand) {
        $raw = $yaml | ConvertFrom-Yaml
    }
    else {
        $raw = ConvertFrom-WapSimpleYaml $yaml
    }

    if (-not $raw.PSObject.Properties['name'] -or [string]::IsNullOrWhiteSpace([string]$raw.name)) {
        throw "Profile '$Name' must define its name."
    }
    if ([string]$raw.name -ne $Name) {
        throw "Profile name '$($raw.name)' does not match directory name '$Name'."
    }

    $workspaceRoot = $config.workspaceRoot
    $profileRoot = [IO.Path]::Combine($workspaceRoot, $Name)
    $sharedRoot = [IO.Path]::Combine($workspaceRoot, '_Shared')

    $variables = @{
        workspaceRoot = $workspaceRoot
        profileRoot = $profileRoot
        sharedRoot = $sharedRoot
        profileName = $Name
    }
    $expand = {
        param([string] $Value)
        if ($null -eq $Value) { return $null }
        foreach ($entry in $variables.GetEnumerator()) {
            $Value = $Value.Replace('${' + $entry.Key + '}', [string]$entry.Value)
        }
        return [Environment]::ExpandEnvironmentVariables($Value)
    }

    $directoryDefaults = [ordered]@{
        Apps      = [IO.Path]::Combine($profileRoot, 'Apps')
        Config    = [IO.Path]::Combine($profileRoot, 'Config')
        Projects  = [IO.Path]::Combine($profileRoot, 'Projects')
        Data      = [IO.Path]::Combine($profileRoot, 'Data')
        Downloads = [IO.Path]::Combine($profileRoot, 'Downloads')
        Cache     = [IO.Path]::Combine($profileRoot, 'Cache')
        Temp      = [IO.Path]::Combine($profileRoot, 'Temp')
    }
    foreach ($key in @('projects', 'data', 'downloads', 'cache')) {
        if ($raw.PSObject.Properties[$key] -and $raw.$key) {
            $label = (Get-Culture).TextInfo.ToTitleCase($key)
            $directoryDefaults[$label] = & $expand ([string]$raw.$key)
        }
    }

    $packages = @()
    if ($raw.PSObject.Properties['apps'] -and $raw.apps) {
        foreach ($app in @($raw.apps)) {
            if ($app -is [string]) {
                $packages += [pscustomobject]@{ id = $app; source = 'winget'; enabled = $true }
            }
            else {
                $id = if ($app -is [System.Collections.IDictionary]) { $app['id'] } else { $app.id }
                $source = if ($app -is [System.Collections.IDictionary]) { $app['source'] } else { $app.source }
                $enabled = if ($app -is [System.Collections.IDictionary]) { $app['enabled'] } else {
                    if ($app.PSObject.Properties['enabled']) { $app.enabled } else { $null }
                }
                if (-not $id) { throw "Every app in '$Name' must have an id." }
                $packages += [pscustomobject]@{
                    id = [string]$id
                    source = if ($source) { [string]$source } else { 'winget' }
                    enabled = ConvertFrom-WapEnabledValue $enabled
                }
            }
        }
    }

    $captureReferences = @()
    if ($raw.PSObject.Properties['captures'] -and $raw.captures) {
        foreach ($capture in @($raw.captures)) {
            if ($capture -is [string]) {
                $captureReferences += [pscustomobject]@{ id = (Get-WapProfileCaptureId $capture); enabled = $true }
            }
            else {
                $id = if ($capture -is [System.Collections.IDictionary]) { $capture['id'] } else { $capture.id }
                $enabled = if ($capture -is [System.Collections.IDictionary]) { $capture['enabled'] } else {
                    if ($capture.PSObject.Properties['enabled']) { $capture.enabled } else { $null }
                }
                if (-not $id) { throw "Every capture in '$Name' must have an id." }
                $captureReferences += [pscustomobject]@{
                    id = Get-WapProfileCaptureId ([string]$id)
                    enabled = ConvertFrom-WapEnabledValue $enabled
                }
            }
        }
    }

    $environment = [ordered]@{}
    if ($raw.PSObject.Properties['env'] -and $raw.env) {
        foreach ($property in $raw.env.PSObject.Properties) {
            $environment[$property.Name] = & $expand ([string]$property.Value
            )
        }
        if ($raw.env -is [System.Collections.IDictionary]) {
            $environment.Clear()
            foreach ($key in $raw.env.Keys) {
                $environment[[string]$key] = & $expand ([string]$raw.env[$key])
            }
        }
    }

    $pathFragments = @()
    if ($raw.PSObject.Properties['path'] -and $raw.path) {
        foreach ($fragment in @($raw.path)) {
            $pathFragments += & $expand ([string]$fragment)
        }
    }

    $shortcuts = @()
    if ($raw.PSObject.Properties['shortcuts'] -and $raw.shortcuts) {
        foreach ($shortcut in @($raw.shortcuts)) {
            if ($shortcut -is [string]) {
                $shortcuts += [pscustomobject]@{
                    name = [IO.Path]::GetFileNameWithoutExtension($shortcut)
                    target = & $expand $shortcut
                    location = 'Desktop'
                }
            }
            else {
                $get = {
                    param($Object, $Key)
                    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Key] }
                    return $Object.$Key
                }
                $target = & $get $shortcut 'target'
                if (-not $target) { throw "Every shortcut in '$Name' must have a target." }
                $shortcutName = & $get $shortcut 'name'
                $shortcutLocation = & $get $shortcut 'location'
                $shortcuts += [pscustomobject]@{
                    name = if ($shortcutName) { [string]$shortcutName } else {
                        [IO.Path]::GetFileNameWithoutExtension([string]$target)
                    }
                    target = & $expand ([string]$target)
                    location = if ($shortcutLocation) { [string]$shortcutLocation } else { 'Desktop' }
                }
            }
        }
    }

    [pscustomobject]@{
        name = $Name
        source = $path
        workspaceRoot = $workspaceRoot
        profileRoot = $profileRoot
        sharedRoot = $sharedRoot
        directories = $directoryDefaults
        apps = $packages
        captures = $captureReferences
        env = $environment
        path = $pathFragments
        shortcuts = $shortcuts
    }
}

function New-WapState {
    [ordered]@{
        version = 1
        activeProfile = $null
        profiles = [ordered]@{}
        registry = [ordered]@{
            enabled = $false
            note = 'Registry deletion is not implemented; dry-run only.'
        }
    }
}

function Get-WapState {
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $path = Join-Path $RepositoryRoot '.wap-state.json'
    if (-not (Test-Path -LiteralPath $path)) { return New-WapState }
    try {
        $state = ConvertTo-WapOrderedHashtable (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
        if (-not $state.Contains('profiles')) { $state.profiles = [ordered]@{} }
        return $state
    }
    catch {
        throw "State file '$path' is invalid: $($_.Exception.Message)"
    }
}

function Save-WapState {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $path = Join-Path $RepositoryRoot '.wap-state.json'
    $temp = "$path.tmp"
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Get-WapProfileState {
    param($State, [string] $Name)
    if ($State.profiles.Contains($Name)) { return $State.profiles[$Name] }
    return $null
}

function Set-WapUserEnvironment {
    param([string] $Name, [AllowNull()][string] $Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Install-WapShortcut {
    param($Shortcut)

    $base = switch ($Shortcut.location.ToLowerInvariant()) {
        'startmenu' { [Environment]::GetFolderPath('StartMenu') }
        default { [Environment]::GetFolderPath('Desktop') }
    }
    $path = Join-Path $base ($Shortcut.name + '.lnk')
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = $Shortcut.target
    $link.Save()
    return $path
}

function Get-WapProfileCapturePlan {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $profile = Import-WapProfile -Name $Name -RepositoryRoot $RepositoryRoot
    $capturesRoot = Get-WapProfileCaptureRoot -ProfileName $Name -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $capturesRoot -PathType Container)) { return @() }
    return @(
        @($profile.captures) |
            ForEach-Object {
                $reference = $_
                $captureRoot = Join-Path $capturesRoot $reference.id
                $metadataPath = Join-Path $captureRoot 'metadata.json'
                $manifestPath = Join-Path $captureRoot 'capture-manifest.json'
                if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
                    throw "Profile '$Name' references capture '$($reference.id)', but '$metadataPath' was not found."
                }
                if ($reference.enabled -and -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                    throw "Profile '$Name' references capture '$($reference.id)', but '$manifestPath' was not found."
                }
                $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
                $selected = if ($metadata.PSObject.Properties['selectedVersion']) { [string]$metadata.selectedVersion } else { 'base' }
                $versions = @($metadata.versions | Where-Object { $null -ne $_ } | Sort-Object version)
                $selectedVersions = if ($selected -eq 'base') {
                    @()
                }
                else {
                    @($versions | Where-Object { $_.version -le $selected } | Select-Object -ExpandProperty version)
                }
                [pscustomobject]@{
                    id = $metadata.id
                    name = $metadata.name
                    enabled = [bool]$reference.enabled
                    selectedVersion = $selected
                    replayVersions = @($selectedVersions)
                    manifestPath = $manifestPath
                }
            }
    )
}

function Invoke-WapWinget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $ErrorMessage
    )

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'winget was not found. Install App Installer or rerun with -WhatIf.' }
    & $winget.Source @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$ErrorMessage (exit $LASTEXITCODE)." }
}

function Write-WapProfileInstallStatus {
    param(
        [Parameter(Mandatory)][string] $ItemType,
        [Parameter(Mandatory)][string] $State,
        [string] $ItemId,
        [int] $Index = 0,
        [int] $Total = 0,
        [string] $ErrorMessage
    )

    $statusPath = $env:WAP_PROFILE_INSTALL_STATUS_PATH
    if ([string]::IsNullOrWhiteSpace($statusPath)) { return }

    $detail = if ($ItemId) {
        $position = if ($Index -gt 0 -and $Total -gt 0) { " $Index/$Total" } else { '' }
        "$ItemType$position $State`: $ItemId"
    }
    else {
        "$ItemType $State"
    }

    try {
        [ordered]@{
            phase = 'installingProfile'
            success = $false
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            stepType = $ItemType
            stepState = $State
            item = $ItemId
            index = $Index
            total = $Total
            detail = $detail
            error = $ErrorMessage
            log = $env:WAP_PROFILE_INSTALL_LOG_PATH
            errorLog = $env:WAP_PROFILE_INSTALL_ERROR_PATH
        } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write profile install status to '$statusPath': $($_.Exception.Message)"
    }
}

function Get-WapWingetInstallArguments {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Source
    )

    return @(
        'install',
        '-e',
        '--id', $Id,
        '--source', $Source,
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
}

function Install-WapProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $profile = Import-WapProfile -Name $Name -RepositoryRoot $RepositoryRoot
    $state = Get-WapState $RepositoryRoot
    $existing = Get-WapProfileState $state $Name
    $installedPackages = if ($existing) { @($existing.installedPackages) } else { @() }
    $createdDirectories = if ($existing) { @($existing.createdDirectories) } else { @() }
    $createdShortcuts = if ($existing) { @($existing.shortcuts) } else { @() }

    Write-Host "Installing profile '$Name'..."
    Write-Host "  Profile root: $($profile.profileRoot)"
    Write-Host "  Shared root:  $($profile.sharedRoot)"
    Write-Host '  Directories:'
    foreach ($directory in @($profile.sharedRoot, $profile.profileRoot) + @($profile.directories.Values)) {
        if (Test-Path -LiteralPath $directory) {
            Write-Host "    [ready]  $directory"
            continue
        }
        Write-Host "    [create] $directory"
        if ($PSCmdlet.ShouldProcess($directory, 'Create directory')) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $createdDirectories += $directory
        }
    }

    $enabledApps = @($profile.apps | Where-Object { $_.enabled })
    Write-Host "  Packages: $($profile.apps.Count) declared ($($enabledApps.Count) enabled)"
    $packageIndex = 0
    foreach ($app in $profile.apps) {
        $packageIndex++
        if (-not $app.enabled) {
            Write-Host "    [disabled] $($app.id) (source: $($app.source))"
            Write-WapProfileInstallStatus -ItemType 'package' -State 'disabled' -ItemId $app.id -Index $packageIndex -Total $profile.apps.Count
            continue
        }
        Write-Host "    [check] $($app.id) (source: $($app.source))"
        Write-WapProfileInstallStatus -ItemType 'package' -State 'checking' -ItemId $app.id -Index $packageIndex -Total $profile.apps.Count
        try {
            if ($PSCmdlet.ShouldProcess($app.id, 'Install winget package')) {
                $winget = Get-Command winget -ErrorAction SilentlyContinue
                if (-not $winget) { throw 'winget was not found. Install App Installer or rerun with -WhatIf.' }
                & $winget.Source list --id $app.id --exact --accept-source-agreements | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    [ready] $($app.id) is already installed"
                    Write-WapProfileInstallStatus -ItemType 'package' -State 'ready' -ItemId $app.id -Index $packageIndex -Total $profile.apps.Count
                    continue
                }
                Write-Host "    [install] $($app.id)"
                Write-WapProfileInstallStatus -ItemType 'package' -State 'installing' -ItemId $app.id -Index $packageIndex -Total $profile.apps.Count
                $installArguments = Get-WapWingetInstallArguments -Id $app.id -Source $app.source
                & $winget.Source @installArguments
                if ($LASTEXITCODE -ne 0) { throw "winget failed to install '$($app.id)' from source '$($app.source)' (exit $LASTEXITCODE)." }
                $installedPackages += $app.id
                Write-Host "    [installed] $($app.id)"
                Write-WapProfileInstallStatus -ItemType 'package' -State 'installed' -ItemId $app.id -Index $packageIndex -Total $profile.apps.Count
            }
        }
        catch {
            Write-WapProfileInstallStatus -ItemType 'package' -State 'failed' -ItemId $app.id -Index $packageIndex -Total $profile.apps.Count -ErrorMessage $_.Exception.Message
            throw
        }
    }

    $capturePlan = @(Get-WapProfileCapturePlan -Name $Name -RepositoryRoot $RepositoryRoot)
    $enabledCapturePlan = @($capturePlan | Where-Object { $_.enabled })
    Write-Host "  Attached captures: $($capturePlan.Count) declared ($($enabledCapturePlan.Count) enabled)"
    $captureIndex = 0
    foreach ($capture in $capturePlan) {
        $captureIndex++
        if (-not $capture.enabled) {
            Write-Host "    [disabled] $($capture.id) selected=$($capture.selectedVersion)"
            Write-WapProfileInstallStatus -ItemType 'capture' -State 'disabled' -ItemId $capture.id -Index $captureIndex -Total $capturePlan.Count
            continue
        }
        $replay = if ($capture.replayVersions.Count) { ($capture.replayVersions -join ', ') } else { 'base only' }
        Write-Host "    [capture] $($capture.id) selected=$($capture.selectedVersion) replay=$replay"
        Write-WapProfileInstallStatus -ItemType 'capture' -State 'applying' -ItemId $capture.id -Index $captureIndex -Total $capturePlan.Count
        Write-WapProfileInstallStatus -ItemType 'capture' -State 'applied' -ItemId $capture.id -Index $captureIndex -Total $capturePlan.Count
    }

    Write-Host "  Shortcuts: $($profile.shortcuts.Count) declared"
    foreach ($shortcut in $profile.shortcuts) {
        Write-Host "    [create] $($shortcut.name)"
        if ($PSCmdlet.ShouldProcess($shortcut.name, 'Create shortcut')) {
            $createdShortcuts += Install-WapShortcut $shortcut
        }
    }

    if (-not $WhatIfPreference) {
        $state.profiles[$Name] = [ordered]@{
            installed = $true
            workspaceRoot = $profile.workspaceRoot
            profileRoot = $profile.profileRoot
            sharedRoot = $profile.sharedRoot
            directories = @($profile.directories.Values)
            createdDirectories = @($createdDirectories)
            packages = @($enabledApps.id)
            installedPackages = @($installedPackages)
            shortcuts = @($createdShortcuts)
            captures = @($enabledCapturePlan)
            activation = if ($existing) { $existing.activation } else { $null }
            installedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-WapState $state $RepositoryRoot
        Write-Host '  State saved.'
    }
    Write-Host "Done: profile '$Name' installed."
    Write-Host "Profile '$Name' is installed but not active. Activate it with:"
    Write-Host "  .\wap.ps1 profile activate $Name"
}

function Disable-WapProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $state = Get-WapState $RepositoryRoot
    $profileState = Get-WapProfileState $state $Name
    if (-not $profileState -or -not $profileState.activation) {
        Write-Host "Profile '$Name' is not active; nothing to deactivate."
        return
    }

    Write-Host "Deactivating profile '$Name'..."
    Write-Host "  Environment variables: $($profileState.activation.environment.Count) owned"
    foreach ($key in @($profileState.activation.environment.Keys)) {
        $record = $profileState.activation.environment[$key]
        $current = [Environment]::GetEnvironmentVariable($key, 'User')
        if ($current -eq $record.applied) {
            Write-Host "    [restore] $key"
            if ($PSCmdlet.ShouldProcess($key, 'Restore user environment variable')) {
                Set-WapUserEnvironment $key $record.previous
            }
        }
        else { Write-Warning "Keeping '$key' because it changed after profile activation." }
    }

    $ownedPath = @($profileState.activation.pathAdded)
    Write-Host "  PATH fragments: $($ownedPath.Count) owned"
    foreach ($fragment in $ownedPath) { Write-Host "    [remove] $fragment" }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathParts = @($userPath -split ';' | Where-Object { $_ })
    foreach ($fragment in $ownedPath) {
        $pathParts = @($pathParts | Where-Object {
            -not [string]::Equals($_.TrimEnd('\'), ([string]$fragment).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
        })
    }
    if ($ownedPath.Count -and $PSCmdlet.ShouldProcess('User PATH', 'Remove profile-owned fragments')) {
        Set-WapUserEnvironment 'Path' ($pathParts -join ';')
    }

    if (-not $WhatIfPreference) {
        $profileState.activation = $null
        if ($state.activeProfile -eq $Name) { $state.activeProfile = $null }
        Save-WapState $state $RepositoryRoot
        Write-Host '  State saved.'
    }
    Write-Host "Done: profile '$Name' deactivated."
}

function Enable-WapProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $profile = Import-WapProfile -Name $Name -RepositoryRoot $RepositoryRoot
    $state = Get-WapState $RepositoryRoot
    $profileState = Get-WapProfileState $state $Name
    if (-not $profileState -or -not $profileState.installed) { throw "Profile '$Name' must be installed before activation." }
    if ($profileState.activation) {
        Write-Host "Profile '$Name' is already active; nothing to change."
        return
    }

    Write-Host "Activating profile '$Name'..."
    Write-Host "  Profile root: $($profile.profileRoot)"
    if ($state.activeProfile -and $state.activeProfile -ne $Name) {
        Write-Host "  Switching from active profile '$($state.activeProfile)'."
        Disable-WapProfile -Name $state.activeProfile -RepositoryRoot $RepositoryRoot -WhatIf:$WhatIfPreference
        $state = Get-WapState $RepositoryRoot
        $profileState = Get-WapProfileState $state $Name
    }

    Write-Host "  Environment variables: $($profile.env.Count) declared"
    $environmentRecords = [ordered]@{}
    foreach ($key in $profile.env.Keys) {
        $previous = [Environment]::GetEnvironmentVariable($key, 'User')
        $applied = [string]$profile.env[$key]
        Write-Host "    [set] $key"
        if ($PSCmdlet.ShouldProcess($key, 'Set user environment variable')) { Set-WapUserEnvironment $key $applied }
        $environmentRecords[$key] = [ordered]@{ previous = $previous; applied = $applied }
    }

    Write-Host "  PATH fragments: $($profile.path.Count) declared"
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathParts = @($userPath -split ';' | Where-Object { $_ })
    $added = @()
    foreach ($fragment in $profile.path) {
        $present = $pathParts | Where-Object {
            [string]::Equals($_.TrimEnd('\'), $fragment.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
        }
        if ($present) { Write-Host "    [ready] $fragment" }
        else {
            Write-Host "    [add] $fragment"
            $pathParts += $fragment
            $added += $fragment
        }
    }
    if ($added.Count -and $PSCmdlet.ShouldProcess('User PATH', 'Add profile fragments')) {
        Set-WapUserEnvironment 'Path' ($pathParts -join ';')
    }

    if (-not $WhatIfPreference) {
        $profileState.activation = [ordered]@{
            environment = $environmentRecords
            pathAdded = $added
            activatedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        $state.activeProfile = $Name
        Save-WapState $state $RepositoryRoot
        Write-Host '  State saved.'
    }
    Write-Host "Done: profile '$Name' activated. Open a new terminal for other processes to see user environment changes."
}

function Get-WapProfileRootForCleanup {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        $ProfileState
    )

    if ($ProfileState -and $ProfileState.PSObject.Properties['profileRoot'] -and $ProfileState.profileRoot) {
        return [string]$ProfileState.profileRoot
    }

    $profile = Import-WapProfile -Name $Name -RepositoryRoot $RepositoryRoot
    return [string]$profile.profileRoot
}

function Get-WapProfileCaptureManifests {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $capturePlan = @(Get-WapProfileCapturePlan -Name $Name -RepositoryRoot $RepositoryRoot | Where-Object { $_.enabled })
    return @(
        $capturePlan |
            ForEach-Object {
                $manifestPath = $_.manifestPath
                try {
                    [pscustomobject]@{
                        Path = $manifestPath
                        Manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                    }
                }
                catch {
                    throw "Attached capture manifest '$manifestPath' is invalid: $($_.Exception.Message)"
                }
            }
    )
}

function ConvertTo-WapRegistryProviderPath {
    param([Parameter(Mandatory)][string] $RegistryKey)

    if ($RegistryKey -match '^(?i)HKEY_CURRENT_USER\\(.+)$') {
        return "Registry::HKEY_CURRENT_USER\$($Matches[1])"
    }
    if ($RegistryKey -match '^(?i)HKCU\\(.+)$') {
        return "Registry::HKEY_CURRENT_USER\$($Matches[1])"
    }
    if ($RegistryKey -match '^(?i)HKEY_LOCAL_MACHINE\\(.+)$') {
        return "Registry::HKEY_LOCAL_MACHINE\$($Matches[1])"
    }
    if ($RegistryKey -match '^(?i)HKLM\\(.+)$') {
        return "Registry::HKEY_LOCAL_MACHINE\$($Matches[1])"
    }
    return $null
}

function Test-WapRegistryCleanupKeySafe {
    param([Parameter(Mandatory)][string] $RegistryKey)

    $key = $RegistryKey.TrimEnd('\')
    if ($key -notmatch '^(?i)(HKEY_CURRENT_USER|HKCU|HKEY_LOCAL_MACHINE|HKLM)\\Software\\') {
        return $false
    }

    $unsafeExact = @(
        'HKEY_CURRENT_USER\Software',
        'HKEY_CURRENT_USER\Software\Classes',
        'HKEY_CURRENT_USER\Software\Classes\Applications',
        'HKEY_LOCAL_MACHINE\Software',
        'HKEY_LOCAL_MACHINE\Software\Microsoft',
        'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows',
        'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT',
        'HKEY_LOCAL_MACHINE\Software\Microsoft\Provisioning'
    )
    foreach ($unsafe in $unsafeExact) {
        if ([string]::Equals($key, $unsafe, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }

    $unsafePrefixes = @(
        'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\',
        'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\',
        'HKEY_LOCAL_MACHINE\Software\Microsoft\Provisioning\'
    )
    foreach ($prefix in $unsafePrefixes) {
        if ($key.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }

    return $true
}

function Get-WapProfileRegistryCleanupKeys {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [switch] $OnlyEnabled
    )

    $keys = [System.Collections.ArrayList]::new()
    $entries = if ($OnlyEnabled) {
        @(Get-WapProfileCaptureManifests -Name $Name -RepositoryRoot $RepositoryRoot)
    }
    else {
        @(Get-WapProfileAllCaptureManifests -Name $Name -RepositoryRoot $RepositoryRoot)
    }
    foreach ($entry in $entries) {
        foreach ($change in @(Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $entry.Manifest -Name changedRegistryKeys))) {
            $key = [string](Get-WapObjectProperty -Object $change -Name key)
            $changeType = [string](Get-WapObjectProperty -Object $change -Name change)
            if ($key -and $changeType -eq 'Added' -and (Test-WapRegistryCleanupKeySafe -RegistryKey $key)) {
                [void]$keys.Add($key.TrimEnd('\'))
            }
        }
    }

    return @($keys.ToArray() | Sort-Object -Unique | Sort-Object Length -Descending)
}

function Get-WapProfileAllCaptureManifests {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $capturesRoot = Join-Path (Join-Path $config.profilesRoot $Name) 'captures'
    if (-not (Test-Path -LiteralPath $capturesRoot -PathType Container)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $capturesRoot -Filter 'capture-manifest.json' -Recurse -File |
            ForEach-Object {
                try {
                    [pscustomobject]@{
                        Path = $_.FullName
                        Manifest = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                    }
                }
                catch {
                    throw "Attached capture manifest '$($_.FullName)' is invalid: $($_.Exception.Message)"
                }
            }
    )
}

function Invoke-WapProfileUserDataCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        $ProfileState
    )

    $profileRoot = Get-WapProfileRootForCleanup -Name $Name -RepositoryRoot $RepositoryRoot -ProfileState $ProfileState
    $profilePath = [IO.Path]::GetFullPath($profileRoot)
    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $workspacePath = [IO.Path]::GetFullPath($config.workspaceRoot)
    if ([IO.Path]::GetDirectoryName($profilePath) -ne $workspacePath) {
        throw "Refusing to delete user data outside workspace root '$workspacePath'. Computed profile path: '$profilePath'."
    }

    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
        Write-Host "  [missing] User data directory '$profilePath'"
        return
    }

    Write-Host "  [delete] User data directory '$profilePath'"
    if ($PSCmdlet.ShouldProcess($profilePath, 'Delete profile user data directory')) {
        Remove-Item -LiteralPath $profilePath -Recurse -Force
    }
}

function Invoke-WapProfileRegistryCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $keys = @(Get-WapProfileRegistryCleanupKeys -Name $Name -RepositoryRoot $RepositoryRoot)
    Write-Host "  Registry cleanup: $($keys.Count) added capture keys eligible"
    if (-not $keys.Count) { return }

    foreach ($key in $keys) {
        $providerPath = ConvertTo-WapRegistryProviderPath -RegistryKey $key
        if (-not $providerPath) {
            Write-Warning "Skipping unsupported registry root: $key"
            continue
        }
        if (Test-Path -LiteralPath $providerPath) {
            Write-Host "    [delete] $key"
            if ($PSCmdlet.ShouldProcess($key, 'Delete captured added registry key')) {
                Remove-Item -LiteralPath $providerPath -Recurse -Force
            }
        }
        else {
            Write-Host "    [missing] $key"
        }
    }
}

function Invoke-WapProfileCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [switch] $RemoveUserData,
        [switch] $RemoveRegistry
    )

    if (-not $RemoveUserData -and -not $RemoveRegistry) {
        throw 'Nothing to clean. Use --user-data, --registry, or --all.'
    }

    $state = Get-WapState $RepositoryRoot
    $profileState = Get-WapProfileState $state $Name
    Write-Host "Cleaning profile '$Name'..."
    if ($RemoveRegistry) {
        $registryKeys = @(Get-WapProfileRegistryCleanupKeys -Name $Name -RepositoryRoot $RepositoryRoot -OnlyEnabled)
        if ($registryKeys | Where-Object { $_ -match '^(?i)(HKEY_LOCAL_MACHINE|HKLM)\\' }) {
            $cleanupArguments = @('profile', 'cleanup', $Name, '--registry')
            if ($RemoveUserData) { $cleanupArguments += '--user-data' }
            if ($WhatIfPreference) { $cleanupArguments += '-WhatIf' }
            Invoke-WapElevatedCommandOrThrow -RepositoryRoot $RepositoryRoot `
                -Arguments $cleanupArguments `
                -Reason "Registry cleanup for '$Name' includes machine-wide HKLM keys and requires administrator rights."
        }
        Invoke-WapProfileRegistryCleanup -Name $Name -RepositoryRoot $RepositoryRoot -WhatIf:$WhatIfPreference
    }
    if ($RemoveUserData) {
        Invoke-WapProfileUserDataCleanup -Name $Name -RepositoryRoot $RepositoryRoot -ProfileState $profileState -WhatIf:$WhatIfPreference
    }
    Write-Host "Done: profile '$Name' cleanup completed."
}

function Uninstall-WapProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [switch] $RemoveUserData,
        [switch] $RemoveRegistry
    )

    $state = Get-WapState $RepositoryRoot
    $profileState = Get-WapProfileState $state $Name
    if (-not $profileState) { throw "Profile '$Name' is not installed." }

    Write-Host "Uninstalling profile '$Name'..."
    Write-Host "  Profile root: $($profileState.profileRoot)"
    if ($profileState.activation) {
        Write-Host '  Profile is active; deactivating it first.'
        Disable-WapProfile -Name $Name -RepositoryRoot $RepositoryRoot -WhatIf:$WhatIfPreference
        $state = Get-WapState $RepositoryRoot
        $profileState = Get-WapProfileState $state $Name
    }

    $packagesUsedElsewhere = @(foreach ($otherName in $state.profiles.Keys) {
        if ($otherName -ne $Name) { $state.profiles[$otherName].packages }
    })
    $ownedPackages = @($profileState.installedPackages)
    $enabledPackageIds = @()
    try {
        $currentProfile = Import-WapProfile -Name $Name -RepositoryRoot $RepositoryRoot
        $enabledPackageIds = @($currentProfile.apps | Where-Object { $_.enabled } | ForEach-Object { $_.id })
    }
    catch {
        Write-Warning "Could not load current profile definition to filter enabled packages: $($_.Exception.Message)"
        $enabledPackageIds = @($ownedPackages)
    }
    Write-Host "  Packages: $($ownedPackages.Count) installed by this profile"
    foreach ($package in $ownedPackages) {
        if ($enabledPackageIds -notcontains $package) {
            Write-Host "    [skip disabled] $package"
            continue
        }
        if ($package -in $packagesUsedElsewhere) {
            Write-Host "    [keep] $package is declared by another profile"
            continue
        }
        Write-Host "    [remove] $package"
        if ($PSCmdlet.ShouldProcess($package, 'Uninstall winget package')) {
            $winget = Get-Command winget -ErrorAction SilentlyContinue
            if (-not $winget) { throw 'winget was not found. Rerun with -WhatIf to preview.' }
            & $winget.Source uninstall --id $package --exact --disable-interactivity
            if ($LASTEXITCODE -ne 0) { throw "winget failed to uninstall '$package' (exit $LASTEXITCODE)." }
        }
    }

    $ownedShortcuts = @($profileState.shortcuts)
    Write-Host "  Shortcuts: $($ownedShortcuts.Count) owned"
    foreach ($shortcut in $ownedShortcuts) {
        if (Test-Path -LiteralPath $shortcut) {
            Write-Host "    [remove] $shortcut"
            if ($PSCmdlet.ShouldProcess($shortcut, 'Remove profile-owned shortcut')) { Remove-Item -LiteralPath $shortcut -Force }
        }
        else { Write-Host "    [missing] $shortcut" }
    }

    if ($RemoveRegistry) {
        $registryKeys = @(Get-WapProfileRegistryCleanupKeys -Name $Name -RepositoryRoot $RepositoryRoot -OnlyEnabled)
        if ($registryKeys | Where-Object { $_ -match '^(?i)(HKEY_LOCAL_MACHINE|HKLM)\\' }) {
            $uninstallArguments = @('profile', 'uninstall', $Name, '--remove-registry')
            if ($RemoveUserData) { $uninstallArguments += '--remove-user-data' }
            if ($WhatIfPreference) { $uninstallArguments += '-WhatIf' }
            Invoke-WapElevatedCommandOrThrow -RepositoryRoot $RepositoryRoot `
                -Arguments $uninstallArguments `
                -Reason "Registry cleanup for '$Name' includes machine-wide HKLM keys and requires administrator rights."
        }
        Invoke-WapProfileRegistryCleanup -Name $Name -RepositoryRoot $RepositoryRoot -WhatIf:$WhatIfPreference
    }
    else {
        Write-Host '  [keep] Registry cleanup disabled. Use --remove-registry to delete added registry keys from attached captures.'
    }

    if ($RemoveUserData) {
        Invoke-WapProfileUserDataCleanup -Name $Name -RepositoryRoot $RepositoryRoot -ProfileState $profileState -WhatIf:$WhatIfPreference
    }
    else {
        Write-Host "  [keep] Workspace directories and user data under '$($profileState.profileRoot)'. Use --remove-user-data to delete them."
    }

    if (-not $WhatIfPreference) {
        $state.profiles.Remove($Name)
        Save-WapState $state $RepositoryRoot
        Write-Host '  State entry removed.'
    }
    Write-Host "Done: profile '$Name' uninstalled."
}

function Show-WapStatus {
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $state = Get-WapState $RepositoryRoot
    $profilesPath = $config.profilesRoot
    $availableNames = @(
        Get-ChildItem -LiteralPath $profilesPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'profile.yaml') } |
            ForEach-Object Name
    )
    $names = @($availableNames + @($state.profiles.Keys) | Sort-Object -Unique)
    $installedCount = @($state.profiles.Keys).Count
    $activeName = if ($state.activeProfile) { [string]$state.activeProfile } else { '<none>' }

    Write-Host "Workspace root:  $($config.workspaceRoot)"
    Write-Host "Profiles root:   $($config.profilesRoot)"
    Write-Host "Active profile: $activeName"
    Write-Host "Installed:      $installedCount"
    if (-not $names.Count) {
        Write-Host 'No profiles are available or installed.'
        return
    }

    $rows = foreach ($name in $names) {
        $isInstalled = $state.profiles.Contains($name) -and [bool]$state.profiles[$name].installed
        $isActive = $isInstalled -and $state.activeProfile -eq $name
        $wingetSummary = ''
        $captureSummary = ''
        $unreferencedCount = 0
        if ($availableNames -contains $name) {
            try {
                $profile = Import-WapProfile -Name $name -RepositoryRoot $RepositoryRoot
                $enabledApps = @($profile.apps | Where-Object { $_.enabled }).Count
                $disabledApps = @($profile.apps | Where-Object { -not $_.enabled }).Count
                $enabledCaptures = @($profile.captures | Where-Object { $_.enabled }).Count
                $disabledCaptures = @($profile.captures | Where-Object { -not $_.enabled }).Count
                $unreferencedCount = @(Get-WapProfileUnreferencedCaptures -ProfileName $name -RepositoryRoot $RepositoryRoot).Count
                $wingetSummary = "$enabledApps enabled / $disabledApps disabled"
                $captureSummary = "$enabledCaptures enabled / $disabledCaptures disabled"
            }
            catch {
                $wingetSummary = 'error'
                $captureSummary = 'error'
            }
        }
        [pscustomobject]@{
            Name = $name
            Installed = $isInstalled
            Status = if ($isActive) { 'Active' } elseif ($isInstalled) { 'Inactive' } else { 'Not installed' }
            Winget = $wingetSummary
            Captures = $captureSummary
            UnreferencedCaptures = $unreferencedCount
            ProfileRoot = [IO.Path]::Combine($config.workspaceRoot, $name)
        }
    }
    $rows | Format-Table -AutoSize
}
function Get-WapCaptureSessionPath {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid capture name '$Name'."
    }
    return Join-Path $RepositoryRoot ".capture/$Name"
}

function Show-WapCaptureSessions {
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $capturesRoot = Join-Path $RepositoryRoot '.capture'
    Write-Host "Standalone capture root: $capturesRoot"
    if (-not (Test-Path -LiteralPath $capturesRoot -PathType Container)) {
        Write-Host 'No standalone captures found.'
        return
    }

    $rows = @(
        Get-ChildItem -LiteralPath $capturesRoot -Directory |
            Sort-Object Name |
            ForEach-Object {
                $sessionPath = Join-Path $_.FullName 'session.json'
                $baselineStatusPath = Join-Path $_.FullName 'baseline/baseline-status.json'
                $manifestPath = Join-Path $_.FullName 'output/capture-manifest.json'
                $createdAt = $null
                $status = 'Started'
                if (Test-Path -LiteralPath $sessionPath -PathType Leaf) {
                    try {
                        $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
                        if ($session.PSObject.Properties['createdAt']) {
                            $createdAt = ConvertTo-WapIsoTimestampString $session.createdAt
                        }
                    }
                    catch {
                        $status = 'InvalidSession'
                    }
                }
                else {
                    $status = 'DirectoryOnly'
                }

                if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                    $status = 'Finalized'
                }
                elseif (Test-Path -LiteralPath $baselineStatusPath -PathType Leaf) {
                    try {
                        $baselineStatus = Get-Content -LiteralPath $baselineStatusPath -Raw | ConvertFrom-Json
                        if ($baselineStatus.success -eq $true) { $status = 'BaselineReady' }
                        elseif ($baselineStatus.success -eq $false) { $status = 'BaselineFailed' }
                    }
                    catch {
                        $status = 'InvalidBaseline'
                    }
                }

                [pscustomobject]@{
                    Name = $_.Name
                    Status = $status
                    CreatedAt = $createdAt
                    Path = $_.FullName
                }
            }
    )

    if (-not $rows.Count) {
        Write-Host 'No standalone captures found.'
        return
    }
    $rows | Format-Table -AutoSize -Wrap
}

function Rename-WapCaptureSession {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $NewName,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $sourcePath = [IO.Path]::GetFullPath((Get-WapCaptureSessionPath -Name $Name -RepositoryRoot $RepositoryRoot))
    $targetPath = [IO.Path]::GetFullPath((Get-WapCaptureSessionPath -Name $NewName -RepositoryRoot $RepositoryRoot))
    $capturesRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot '.capture'))
    if ([IO.Path]::GetDirectoryName($sourcePath) -ne $capturesRoot -or
        [IO.Path]::GetDirectoryName($targetPath) -ne $capturesRoot) {
        throw "Refusing to rename a path outside '$capturesRoot'."
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Capture session '$Name' was not found at '$sourcePath'."
    }
    if (Test-Path -LiteralPath $targetPath) {
        throw "Capture session '$NewName' already exists at '$targetPath'."
    }

    Write-Host "Renaming capture session '$Name' to '$NewName'..."
    Write-Host "  [from] $sourcePath"
    Write-Host "  [to]   $targetPath"
    if ($PSCmdlet.ShouldProcess($sourcePath, "Rename capture session to '$NewName'")) {
        Rename-Item -LiteralPath $sourcePath -NewName $NewName
        $sessionPath = Join-Path $targetPath 'session.json'
        if (Test-Path -LiteralPath $sessionPath -PathType Leaf) {
            $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
            Set-WapObjectProperty -Object $session -Name profileName -Value $NewName
            Set-WapObjectProperty -Object $session -Name renamedFrom -Value $Name
            Set-WapObjectProperty -Object $session -Name renamedAt -Value ((Get-Date).ToUniversalTime().ToString('o'))
            $session | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sessionPath -Encoding UTF8
        }
        $manifestPath = Join-Path $targetPath 'output/capture-manifest.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            Set-WapObjectProperty -Object $manifest -Name profileName -Value $NewName
            Set-WapObjectProperty -Object $manifest -Name renamedFrom -Value $Name
            Set-WapObjectProperty -Object $manifest -Name renamedAt -Value ((Get-Date).ToUniversalTime().ToString('o'))
            $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        }
        Write-Host "Done: capture session '$Name' renamed to '$NewName'."
    }
}

function Wait-WapCaptureBaseline {
    param(
        [Parameter(Mandatory)][string] $CaptureRoot,
        $SandboxProcess,
        [int] $TimeoutSeconds = 900
    )

    $statusPath = Join-Path $CaptureRoot 'baseline/baseline-status.json'
    $snapshotPath = Join-Path $CaptureRoot 'baseline/snapshot.json'
    $startupStatusPath = Join-Path $CaptureRoot 'output/startup-status.json'
    $wingetLogPath = Join-Path $CaptureRoot 'output/winget-install.log'
    $wingetErrorPath = Join-Path $CaptureRoot 'output/winget-install-error.txt'
    $started = Get-Date
    $lastReport = -15
    $lastStartupPhase = $null
    Write-Host "Waiting for Sandbox baseline to finish (timeout: $TimeoutSeconds seconds)..."
    try {
        while ($true) {
            if (Test-Path -LiteralPath $wingetErrorPath -PathType Leaf) {
                $wingetError = (Get-Content -LiteralPath $wingetErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
                if ($wingetError.Length -gt 600) { $wingetError = $wingetError.Substring(0, 600) + '...' }
                throw "Sandbox winget setup failed before baseline capture. $wingetError`nDetailed winget log: $wingetLogPath`nDetailed winget error: $wingetErrorPath"
            }

            if (Test-Path -LiteralPath $startupStatusPath -PathType Leaf) {
                try {
                    $startupStatus = Get-Content -LiteralPath $startupStatusPath -Raw | ConvertFrom-Json
                    if ($startupStatus.success -eq $false -and $startupStatus.phase -eq 'failed') {
                        throw "Sandbox startup failed before baseline capture: $($startupStatus.error). Detailed winget log: $wingetLogPath. Detailed winget error: $wingetErrorPath"
                    }
                    if ($startupStatus.phase -and $startupStatus.phase -ne $lastStartupPhase) {
                        Write-Host "  Sandbox startup phase: $($startupStatus.phase)"
                        if ($startupStatus.phase -eq 'installingWinget') {
                            Write-Host "  Winget setup log: $wingetLogPath"
                        }
                        $lastStartupPhase = $startupStatus.phase
                    }
                }
                catch {
                    if ($_.Exception.Message -like 'Sandbox startup failed before baseline capture:*') { throw }
                    # The Sandbox may still be writing the status file; retry.
                }
            }

            if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                try {
                    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                    if ($status.success -eq $true -and (Test-Path -LiteralPath $snapshotPath)) {
                        $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json
                        Write-Host ''
                        Write-Host '=== BASELINE READY ===' -ForegroundColor Green
                        if ($snapshot.currentUser) {
                            Write-Host "Captured Sandbox user: $($snapshot.currentUser.qualifiedName)"
                            Write-Host "Captured user profile: $($snapshot.currentUser.profilePath)"
                        }
                        Write-Host 'You may now interact with the Sandbox and install/configure applications.'
                        Write-Host 'Optional: if you install tools that should be part of the baseline, rerun baseline capture inside Sandbox with:'
                        Write-Host '  powershell.exe -ExecutionPolicy Bypass -File C:\WAPCapture\Capture-Baseline.ps1'
                        return
                    }
                    if ($status.success -eq $false) {
                        throw "Sandbox baseline failed: $($status.error). See '$CaptureRoot\output\baseline-error.txt'."
                    }
                }
                catch {
                    if ($_.Exception.Message -like 'Sandbox baseline failed:*') { throw }
                    # The Sandbox may still be atomically finishing the status file; retry.
                }
            }

            if ($SandboxProcess) {
                try {
                    if ($SandboxProcess.PSObject.Methods['Refresh']) { $SandboxProcess.Refresh() }
                    if ($SandboxProcess.HasExited) {
                        throw "Windows Sandbox exited before baseline completion. See '$CaptureRoot\output\baseline.log'."
                    }
                }
                catch {
                    if ($_.Exception.Message -like 'Windows Sandbox exited:*') { throw }
                }
            }

            $elapsed = [int]((Get-Date) - $started).TotalSeconds
            if ($elapsed -ge $TimeoutSeconds) {
                throw "Timed out waiting for baseline after $TimeoutSeconds seconds. Sandbox was left open; inspect '$CaptureRoot\output\baseline.log'."
            }
            if (($elapsed - $lastReport) -ge 15) {
                if ($lastStartupPhase -and $lastStartupPhase -ne 'startingBaseline') {
                    Write-Host "  Still waiting for Sandbox startup ($lastStartupPhase)... $elapsed seconds elapsed"
                    if (Test-Path -LiteralPath $wingetLogPath -PathType Leaf) {
                        Write-Host "  Winget setup log: $wingetLogPath"
                    }
                }
                else {
                    Write-Host "  Still capturing baseline... $elapsed seconds elapsed"
                }
                $lastReport = $elapsed
            }
            Write-Progress -Activity 'WindowsAutoProfiles Sandbox capture' -Status 'Recording baseline' `
                -SecondsRemaining ([Math]::Max(0, $TimeoutSeconds - $elapsed))
            Start-Sleep -Seconds 1
        }
    }
    finally {
        Write-Progress -Activity 'WindowsAutoProfiles Sandbox capture' -Completed
    }
}

function Wait-WapProfileSandboxInstall {
    param(
        [Parameter(Mandatory)][string] $SessionRoot,
        $SandboxProcess,
        [int] $TimeoutSeconds = 1800
    )

    $statusPath = Join-Path $SessionRoot 'output/status.json'
    $logPath = Join-Path $SessionRoot 'output/profile-install.log'
    $errorPath = Join-Path $SessionRoot 'output/profile-install-error.txt'
    $started = Get-Date
    $lastReport = -15
    $lastPhase = $null
    $lastDetail = $null
    $processExitedAt = $null
    $reportedProcessExit = $false
    Write-Host "Waiting for Sandbox profile install to finish (timeout: $TimeoutSeconds seconds)..."
    try {
        while ($true) {
            if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                try {
                    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                    if ($status.phase -and $status.phase -ne $lastPhase) {
                        Write-Host "  Sandbox profile install phase: $($status.phase)"
                        Write-Host "  Sandbox install log: $logPath"
                        $lastPhase = $status.phase
                    }
                    if ($status.success -eq $true -and $status.phase -eq 'completed') {
                        Write-Host ''
                        Write-Host '=== SANDBOX PROFILE INSTALL COMPLETE ===' -ForegroundColor Green
                        Write-Host "Detailed Sandbox install log: $logPath"
                        Write-Host 'The Sandbox window remains open for manual profile lifecycle testing.'
                        Write-Host 'Inside Sandbox, run commands from C:\WAPProfileSandbox\repo, for example:'
                        Write-Host '  .\wap.ps1 profile list'
                        Write-Host '  .\wap.ps1 profile install <profile>'
                        Write-Host '  .\wap.ps1 profile activate <profile>'
                        Write-Host '  .\wap.ps1 profile deactivate <profile>'
                        Write-Host '  .\wap.ps1 profile uninstall <profile>'
                        Write-Host 'Command guide inside Sandbox: C:\WAPProfileSandbox\profile-testing.md'
                        return
                    }
                    $statusDetail = if ($status.PSObject.Properties['detail']) { [string]$status.detail } else { $null }
                    $stepState = if ($status.PSObject.Properties['stepState']) { [string]$status.stepState } else { $null }
                    if ($statusDetail -and $statusDetail -ne $lastDetail) {
                        $detailPrefix = if ($stepState -eq 'failed') { '  Sandbox profile install failed step:' } else { '  Sandbox profile install step:' }
                        Write-Host "$detailPrefix $statusDetail"
                        if ($stepState -eq 'failed' -and $status.error) {
                            Write-Host "  Failure: $($status.error)"
                        }
                        $lastDetail = $statusDetail
                    }
                    if ($status.success -eq $false -and $status.phase -eq 'failed') {
                        $details = if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
                            (Get-Content -LiteralPath $errorPath -Raw -ErrorAction SilentlyContinue).Trim()
                        }
                        else {
                            $detailMessage = if ($statusDetail) { "$statusDetail. " } else { '' }
                            "$detailMessage$($status.error)"
                        }
                        if ($details.Length -gt 700) { $details = $details.Substring(0, 700) + '...' }
                        throw "Sandbox profile install failed. $details`nDetailed Sandbox install log: $logPath`nDetailed Sandbox install error: $errorPath"
                    }
                }
                catch {
                    if ($_.Exception.Message -like 'Sandbox profile install failed.*') { throw }
                    # The Sandbox may still be writing the status file; retry.
                }
            }

            if ($SandboxProcess) {
                try {
                    $SandboxProcess.Refresh()
                    if ($SandboxProcess.HasExited) {
                        if (-not $processExitedAt) {
                            $processExitedAt = Get-Date
                        }
                        if (-not $reportedProcessExit) {
                            Write-Warning 'WindowsSandbox.exe launcher process exited; continuing to monitor Sandbox status files.'
                            $reportedProcessExit = $true
                        }
                    }
                }
                catch {
                    Write-Warning "Could not refresh Windows Sandbox process state: $($_.Exception.Message)"
                }
            }

            $elapsed = [int]((Get-Date) - $started).TotalSeconds
            if ($processExitedAt -and -not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
                $elapsedSinceProcessExit = [int]((Get-Date) - $processExitedAt).TotalSeconds
                if ($elapsedSinceProcessExit -ge 120) {
                    throw "Windows Sandbox launcher exited and no Sandbox status file was created after 120 seconds. Check '$logPath' and '$SessionRoot'."
                }
            }
            if ($elapsed -ge $TimeoutSeconds) {
                throw "Timed out waiting for Sandbox profile install after $TimeoutSeconds seconds. Check '$logPath'."
            }
            if (($elapsed - $lastReport) -ge 15) {
                $phase = if ($lastPhase) { $lastPhase } else { 'starting' }
                Write-Host "  Still waiting for Sandbox profile install ($phase)... $elapsed seconds elapsed"
                $lastReport = $elapsed
            }
            Start-Sleep -Seconds 2
        }
    }
    finally {
        Write-Progress -Activity 'WindowsAutoProfiles Sandbox profile install' -Completed
    }
}

function New-WapProfileSandboxStartupScript {
    param([Parameter(Mandatory)][string] $ProfileName)

    $escapedProfileName = $ProfileName.Replace("'", "''")
    return @"
#requires -Version 5.1
`$ErrorActionPreference = 'Stop'
`$profileName = '$escapedProfileName'
`$sessionRoot = 'C:\WAPProfileSandbox'
`$output = Join-Path `$sessionRoot 'output'
`$statusPath = Join-Path `$output 'status.json'
`$errorPath = Join-Path `$output 'profile-install-error.txt'
`$logPath = Join-Path `$output 'profile-install.log'
New-Item -ItemType Directory -Path `$output -Force | Out-Null

function Write-InstallStatus {
    param(
        [Parameter(Mandatory)][string] `$Phase,
        [Parameter(Mandatory)][bool] `$Success,
        [AllowNull()][string] `$ErrorMessage
    )

    [pscustomobject]@{
        phase = `$Phase
        success = `$Success
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        error = `$ErrorMessage
        log = `$logPath
        errorLog = `$errorPath
    } | ConvertTo-Json | Set-Content -LiteralPath `$statusPath -Encoding UTF8
}

Write-Host ''
Write-Host '=== WindowsAutoProfiles Sandbox profile install ===' -ForegroundColor Cyan
Write-Host "Profile: `$profileName"
Write-Host "Detailed install log: `$logPath"
Write-Host ''

function Write-ManualTestingGuide {
    `$guidePath = Join-Path `$sessionRoot 'profile-testing.md'
    @(
        '# WindowsAutoProfiles Sandbox profile testing'
        ''
        'The sandbox is configured with a temporary local WAP configuration.'
        ''
        '- Local repo: C:\WAPProfileSandbox\repo'
        '- Mounted profiles: C:\WAPProfiles'
        '- Sandbox workspaces: C:\WAPProfileSandbox\workspaces'
        '- Logs: C:\WAPProfileSandbox\output\logs'
        ''
        'Run these commands from C:\WAPProfileSandbox\repo:'
        ''
        '~~~powershell'
        '.\wap.ps1 profile list'
        '.\wap.ps1 profile show <profile>'
        '.\wap.ps1 profile install <profile>'
        '.\wap.ps1 profile activate <profile>'
        '.\wap.ps1 profile deactivate <profile>'
        '.\wap.ps1 profile uninstall <profile>'
        '.\wap.ps1 profile uninstall <profile> --remove-user-data --remove-registry'
        '~~~'
        ''
        'Profiles are mounted read-only from the host, so edit profile definitions on the'
        'host and relaunch the sandbox test to pick up changes.'
    ) | Set-Content -LiteralPath `$guidePath -Encoding UTF8

    Write-Host ''
    Write-Host '=== MANUAL PROFILE TESTING READY ===' -ForegroundColor Green
    Write-Host 'This Sandbox PowerShell is configured for manual profile lifecycle testing.'
    Write-Host "Run commands from: `$sandboxRepo"
    Write-Host 'Mounted profiles: C:\WAPProfiles'
    Write-Host "Command guide: `$guidePath"
    Write-Host ''
    Write-Host 'Examples:'
    Write-Host '  .\wap.ps1 profile list'
    Write-Host '  .\wap.ps1 profile install <profile>'
    Write-Host '  .\wap.ps1 profile activate <profile>'
    Write-Host '  .\wap.ps1 profile deactivate <profile>'
    Write-Host '  .\wap.ps1 profile uninstall <profile>'
    Write-Host ''
}

`$transcriptStarted = `$false
try {
    Start-Transcript -LiteralPath `$logPath -Force | Out-Null
    `$transcriptStarted = `$true
}
catch {
    Write-Warning "Transcript could not start: `$(`$_.Exception.Message)"
}

try {
    Write-InstallStatus -Phase 'copyingRepo' -Success `$false -ErrorMessage `$null
    Write-Host 'Phase: copying scripts into Sandbox-local repo.' -ForegroundColor Cyan
    `$sandboxRepo = Join-Path `$sessionRoot 'repo'
    if (Test-Path -LiteralPath `$sandboxRepo -PathType Container) {
        Remove-Item -LiteralPath `$sandboxRepo -Recurse -Force
    }
    New-Item -ItemType Directory -Path `$sandboxRepo -Force | Out-Null
    foreach (`$repoItem in @('wap.ps1', 'src', 'templates', 'docs', 'README.md')) {
        `$sourceItem = Join-Path 'C:\WAPRepo' `$repoItem
        if (Test-Path -LiteralPath `$sourceItem) {
            Copy-Item -LiteralPath `$sourceItem -Destination `$sandboxRepo -Recurse -Force
        }
    }

    Write-InstallStatus -Phase 'configuring' -Success `$false -ErrorMessage `$null
    Write-Host 'Phase: configuring Sandbox-local WAP settings before init.' -ForegroundColor Cyan
    [ordered]@{
        version = 1
        configPath = 'wap.settings.json'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path `$sandboxRepo 'wap.config.json') -Encoding UTF8
    [ordered]@{
        version = 1
        workspaceRoot = 'C:\WAPProfileSandbox\workspaces'
        profilesRoot = 'C:\WAPProfiles'
        logging = [ordered]@{
            enabled = `$true
            retentionDays = 30
            root = 'C:\WAPProfileSandbox\output\logs'
        }
        sandbox = [ordered]@{
            installWinget = `$true
        }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path `$sandboxRepo 'wap.settings.json') -Encoding UTF8

    Write-InstallStatus -Phase 'initializing' -Success `$false -ErrorMessage `$null
    Write-Host 'Phase: running wap init inside Sandbox.' -ForegroundColor Cyan
    `$env:WAP_WINGET_PREREQ_ROOT = Join-Path `$sessionRoot 'prereqs\winget'
    Set-Location `$sandboxRepo
    & .\wap.ps1 init
    if (-not `$?) {
        `$exitDescription = if (`$null -ne `$LASTEXITCODE) { " with exit code `$LASTEXITCODE" } else { '' }
        throw "wap init failed`$exitDescription."
    }

    Write-InstallStatus -Phase 'installingProfile' -Success `$false -ErrorMessage `$null
    Write-Host 'Phase: installing profile inside Sandbox.' -ForegroundColor Cyan
    `$env:WAP_PROFILE_INSTALL_STATUS_PATH = `$statusPath
    `$env:WAP_PROFILE_INSTALL_LOG_PATH = `$logPath
    `$env:WAP_PROFILE_INSTALL_ERROR_PATH = `$errorPath
    & .\wap.ps1 profile install `$profileName
    if (-not `$?) {
        `$exitDescription = if (`$null -ne `$LASTEXITCODE) { " with exit code `$LASTEXITCODE" } else { '' }
        throw "profile install failed`$exitDescription."
    }

    Write-InstallStatus -Phase 'completed' -Success `$true -ErrorMessage `$null
    Write-Host ''
    Write-Host '=== PROFILE INSTALL COMPLETE ===' -ForegroundColor Green
    Set-Location `$sandboxRepo
    Write-ManualTestingGuide
}
catch {
    `$message = `$_.Exception.Message
    (`$_ | Out-String) | Set-Content -LiteralPath `$errorPath -Encoding UTF8
    Write-InstallStatus -Phase 'failed' -Success `$false -ErrorMessage `$message
    Write-Host ''
    Write-Host '=== PROFILE INSTALL FAILED ===' -ForegroundColor Red
    Write-Host `$message -ForegroundColor Red
    Write-Host "Details: `$errorPath"
    throw
}
finally {
    if (`$sandboxRepo -and (Test-Path -LiteralPath `$sandboxRepo -PathType Container)) {
        Set-Location `$sandboxRepo
    }
    if (`$transcriptStarted) { Stop-Transcript | Out-Null }
}
"@
}

function Start-WapProfileSandboxInstall {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [int] $TimeoutSeconds = 1800
    )

    $profile = Import-WapProfile -Name $Name -RepositoryRoot $RepositoryRoot
    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $sessionRoot = Join-Path (Join-Path $RepositoryRoot '.sandbox\profile-install') $Name
    $profilesRoot = [IO.Path]::GetFullPath($config.profilesRoot)

    Write-Host "Starting Sandbox profile install test for '$Name'..."
    Write-Host "  Host session root: $sessionRoot"
    Write-Host "  Mounted scripts:    $RepositoryRoot"
    Write-Host "  Mounted profiles:   $profilesRoot"
    Write-Host "  Sandbox workspace:  C:\WAPProfileSandbox\workspaces"

    if ($PSCmdlet.ShouldProcess($sessionRoot, "Create Sandbox profile install session for '$Name'")) {
        if (Test-Path -LiteralPath $sessionRoot -PathType Container) {
            Remove-Item -LiteralPath $sessionRoot -Recurse -Force
        }
        foreach ($directory in @('output', 'prereqs')) {
            New-Item -ItemType Directory -Path (Join-Path $sessionRoot $directory) -Force | Out-Null
            Write-Host "  [created] $directory/"
        }

        Save-WapSandboxWingetPrerequisites -CaptureRoot $sessionRoot

        $startupScript = New-WapProfileSandboxStartupScript -ProfileName $profile.name
        $startupPath = Join-Path $sessionRoot 'Profile-Install-Startup.ps1'
        $startupScript | Set-Content -LiteralPath $startupPath -Encoding utf8
        Write-Host '  [generated] Profile-Install-Startup.ps1'

        $escapedSessionRoot = [Security.SecurityElement]::Escape($sessionRoot)
        $escapedRepositoryRoot = [Security.SecurityElement]::Escape([IO.Path]::GetFullPath($RepositoryRoot))
        $escapedProfilesRoot = [Security.SecurityElement]::Escape($profilesRoot)
        $wsb = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$escapedSessionRoot</HostFolder>
      <SandboxFolder>C:\WAPProfileSandbox</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$escapedRepositoryRoot</HostFolder>
      <SandboxFolder>C:\WAPRepo</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$escapedProfilesRoot</HostFolder>
      <SandboxFolder>C:\WAPProfiles</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File C:\WAPProfileSandbox\Profile-Install-Startup.ps1</Command>
  </LogonCommand>
</Configuration>
"@
        $wsbPath = Join-Path $sessionRoot 'sandbox.wsb'
        $wsb | Set-Content -LiteralPath $wsbPath -Encoding utf8
        Write-Host '  [generated] sandbox.wsb'

        $sandboxCommand = Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue
        if (-not $sandboxCommand) {
            $fallback = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
            if (Test-Path -LiteralPath $fallback) {
                $sandboxCommand = [pscustomobject]@{ Source = $fallback }
            }
        }
        if (-not $sandboxCommand) {
            Write-Warning 'Windows Sandbox is unavailable. Enable the Windows Sandbox optional feature, then open sandbox.wsb manually.'
            return
        }

        Write-Host '  [launch] Windows Sandbox'
        $sandboxProcess = Start-Process -FilePath $sandboxCommand.Source -ArgumentList $wsbPath -PassThru
        Write-Host 'Sandbox launched. Watch the visible Sandbox PowerShell window for live install progress.'
        if ($sandboxProcess) {
            Wait-WapProfileSandboxInstall -SessionRoot $sessionRoot -SandboxProcess $sandboxProcess -TimeoutSeconds $TimeoutSeconds
        }
        else {
            Write-Warning "Could not get the Windows Sandbox process handle; watch the Sandbox window and log at '$sessionRoot\output\profile-install.log'."
        }
    }
}

function Save-WapSandboxWingetPrerequisites {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot)

    $prereqRoot = Join-Path $CaptureRoot 'prereqs\winget'
    $dependencyZipPath = Join-Path $prereqRoot 'DesktopAppInstaller_Dependencies.zip'
    $dependencyExtractRoot = Join-Path $prereqRoot 'DesktopAppInstaller_Dependencies'
    $vclibsPath = Join-Path $prereqRoot 'Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx'
    $vclibsDesktopPath = Join-Path $prereqRoot 'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx'
    $windowsAppRuntimePath = Join-Path $prereqRoot 'Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64.appx'
    $appInstallerPath = Join-Path $prereqRoot 'Microsoft.DesktopAppInstaller.msixbundle'

    New-Item -ItemType Directory -Path $prereqRoot -Force | Out-Null

    if ((Test-Path -LiteralPath $vclibsPath -PathType Leaf) -and
        (Test-Path -LiteralPath $vclibsDesktopPath -PathType Leaf) -and
        (Test-Path -LiteralPath $windowsAppRuntimePath -PathType Leaf) -and
        (Test-Path -LiteralPath $appInstallerPath -PathType Leaf)) {
        Write-Host "  [reuse] Sandbox winget prerequisites: $prereqRoot"
        return
    }

    Write-Host "  [download] Sandbox winget prerequisites: $prereqRoot"
    if (-not (Test-Path -LiteralPath $appInstallerPath -PathType Leaf)) {
        Write-Host '    Microsoft.DesktopAppInstaller.msixbundle'
        Invoke-WebRequest -Uri 'https://github.com/microsoft/winget-cli/releases/download/v1.29.280/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' -OutFile $appInstallerPath -UseBasicParsing
    }
    if ((-not (Test-Path -LiteralPath $vclibsPath -PathType Leaf)) -or
        (-not (Test-Path -LiteralPath $vclibsDesktopPath -PathType Leaf)) -or
        (-not (Test-Path -LiteralPath $windowsAppRuntimePath -PathType Leaf))) {
        if (-not (Test-Path -LiteralPath $dependencyZipPath -PathType Leaf)) {
            Write-Host '    DesktopAppInstaller_Dependencies.zip'
            Invoke-WebRequest -Uri 'https://github.com/microsoft/winget-cli/releases/download/v1.29.280/DesktopAppInstaller_Dependencies.zip' -OutFile $dependencyZipPath -UseBasicParsing
        }
        if (Test-Path -LiteralPath $dependencyExtractRoot -PathType Container) {
            Remove-Item -LiteralPath $dependencyExtractRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $dependencyExtractRoot -Force | Out-Null
        Expand-Archive -LiteralPath $dependencyZipPath -DestinationPath $dependencyExtractRoot -Force

        foreach ($dependencyName in @(
                'Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx',
                'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx',
                'Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64.appx'
            )) {
            $dependency = Get-ChildItem -LiteralPath $dependencyExtractRoot -Recurse -File -Filter $dependencyName |
                Select-Object -First 1
            if (-not $dependency) {
                throw "Could not find '$dependencyName' inside '$dependencyZipPath'."
            }
            Copy-Item -LiteralPath $dependency.FullName -Destination (Join-Path $prereqRoot $dependencyName) -Force
        }
    }
}

function Start-WapInteractiveCapture {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [int] $BaselineTimeoutSeconds = 900,
        [switch] $NoWinget
    )

    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $installWingetInSandbox = $config.sandboxInstallWinget -and -not $NoWinget
    $captureRoot = Get-WapCaptureSessionPath -Name $Name -RepositoryRoot $RepositoryRoot
    if (Test-Path -LiteralPath $captureRoot) {
        throw "Capture session '$Name' already exists at '$captureRoot'. No files were overwritten."
    }

    $templateRoot = Join-Path $RepositoryRoot 'templates/capture'
    $requiredTemplates = @(
        'Capture-Common.ps1',
        'Capture-Startup.ps1',
        'Capture-Baseline.ps1',
        'Capture-Finalize.ps1',
        'capture-filters.json',
        'sandbox.wsb.template'
    )
    foreach ($template in $requiredTemplates) {
        if (-not (Test-Path -LiteralPath (Join-Path $templateRoot $template))) {
            throw "Capture template '$template' is missing from '$templateRoot'."
        }
    }

    Write-Host "Starting interactive capture for profile '$Name'..."
    Write-Host "  Host capture root: $captureRoot"
    if ($installWingetInSandbox) {
        Write-Host '  Sandbox winget bootstrap: enabled'
    }
    else {
        Write-Host '  Sandbox winget bootstrap: disabled'
    }
    if ($PSCmdlet.ShouldProcess($captureRoot, 'Create capture session and launch Windows Sandbox')) {
        foreach ($directory in @('baseline', 'after', 'output')) {
            New-Item -ItemType Directory -Path (Join-Path $captureRoot $directory) -Force | Out-Null
            Write-Host "  [created] $directory/"
        }
        if ($installWingetInSandbox) {
            Save-WapSandboxWingetPrerequisites -CaptureRoot $captureRoot
        }
        foreach ($scriptName in @('Capture-Common.ps1', 'Capture-Baseline.ps1', 'Capture-Finalize.ps1', 'capture-filters.json')) {
            Copy-Item -LiteralPath (Join-Path $templateRoot $scriptName) -Destination (Join-Path $captureRoot $scriptName)
            Write-Host "  [generated] $scriptName"
        }
        $startupScript = Get-Content -LiteralPath (Join-Path $templateRoot 'Capture-Startup.ps1') -Raw
        $wingetFlag = if ($installWingetInSandbox) { '$true' } else { '$false' }
        $startupScript.Replace('__INSTALL_WINGET_IN_SANDBOX__', $wingetFlag) |
            Set-Content -LiteralPath (Join-Path $captureRoot 'Capture-Startup.ps1') -Encoding utf8
        Write-Host '  [generated] Capture-Startup.ps1'

        [ordered]@{
            version = 1
            profileName = $Name
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
            sandbox = [ordered]@{
                installWinget = $installWingetInSandbox
            }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $captureRoot 'session.json') -Encoding utf8

        $escapedHostPath = [Security.SecurityElement]::Escape($captureRoot)
        $wsb = Get-Content -LiteralPath (Join-Path $templateRoot 'sandbox.wsb.template') -Raw
        $wsb.Replace('__HOST_CAPTURE_ROOT__', $escapedHostPath) |
            Set-Content -LiteralPath (Join-Path $captureRoot 'sandbox.wsb') -Encoding utf8
        Write-Host '  [generated] sandbox.wsb'

        $sandboxCommand = Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue
        if (-not $sandboxCommand) {
            $fallback = Join-Path $env:WINDIR 'System32/WindowsSandbox.exe'
            if (Test-Path -LiteralPath $fallback) {
                $sandboxCommand = [pscustomobject]@{ Source = $fallback }
            }
        }
        if (-not $sandboxCommand) {
            Write-Warning 'Windows Sandbox is unavailable. Enable the Windows Sandbox optional feature, then open sandbox.wsb manually.'
            return
        }

        Write-Host '  [launch] Windows Sandbox'
        $sandboxProcess = Start-Process -FilePath $sandboxCommand.Source -ArgumentList (Join-Path $captureRoot 'sandbox.wsb') -PassThru
        Write-Host 'Sandbox launched.'
        if ($sandboxProcess) {
            Wait-WapCaptureBaseline -CaptureRoot $captureRoot -SandboxProcess $sandboxProcess -TimeoutSeconds $BaselineTimeoutSeconds
        }
        else {
            Write-Warning 'Could not get the Windows Sandbox process handle; watch the Sandbox window for BASELINE READY before installing apps.'
        }
        Write-Host 'When the baseline is correct and application setup is finished, finalize inside Sandbox with:'
        Write-Host '  powershell.exe -ExecutionPolicy Bypass -File C:\WAPCapture\Capture-Finalize.ps1'
    }
}

function Read-WapCaptureManifest {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [int] $BaselineTimeoutSeconds = 900
    )

    $captureRoot = Get-WapCaptureSessionPath -Name $Name -RepositoryRoot $RepositoryRoot
    $manifestPath = Join-Path $captureRoot 'output/capture-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Capture manifest not found at '$manifestPath'. In Sandbox, run C:\WAPCapture\Capture-Finalize.ps1 first."
    }
    try {
        return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Capture manifest '$manifestPath' is invalid: $($_.Exception.Message)"
    }
}

function Read-WapCaptureJsonItems {
    param($Value)

    if ($null -eq $Value) { return @() }
    if ($Value.PSObject.Properties['value'] -and
        $Value.PSObject.Properties['Capacity'] -and
        $Value.PSObject.Properties['Count']) {
        return @($Value.value | Where-Object { $null -ne $_ })
    }
    return @($Value | Where-Object { $null -ne $_ })
}

function Get-WapObjectProperty {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)][string] $Name
    )

    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

function Get-WapCaptureFilters {
    param(
        [Parameter(Mandatory)][string] $CaptureRoot,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $candidatePaths = @(
        (Join-Path $CaptureRoot 'capture-filters.json'),
        (Join-Path $RepositoryRoot 'templates/capture/capture-filters.json')
    )
    $path = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $path) {
        throw "Capture filter file was not found. Checked: $($candidatePaths -join ', ')."
    }
    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Capture filter file '$path' is invalid: $($_.Exception.Message)"
    }
}

function Get-WapCaptureNoiseReason {
    param(
        $Rules,
        [Parameter(Mandatory)][string] $Value
    )

    foreach ($rule in @($Rules)) {
        if ($Value -match ([string]$rule.pattern)) { return [string]$rule.reason }
    }
    return $null
}

function Get-WapCaptureUninstallNoiseReason {
    param(
        $Rules,
        [Parameter(Mandatory)] $UninstallCommand
    )

    $command = [string](Get-WapObjectProperty -Object $UninstallCommand -Name command)
    $path = [string](Get-WapObjectProperty -Object $UninstallCommand -Name path)
    $registryKey = [string](Get-WapObjectProperty -Object $UninstallCommand -Name registryKey)
    foreach ($rule in @($Rules)) {
        if (($rule.PSObject.Properties['commandPattern'] -and $command -match ([string]$rule.commandPattern) ) -or
            ($rule.PSObject.Properties['pathPattern'] -and $path -match ([string]$rule.pathPattern) ) -or
            ($rule.PSObject.Properties['registryKeyPattern'] -and $registryKey -match ([string]$rule.registryKeyPattern) )) {
            return [string]$rule.reason
        }
    }
    return $null
}

function Add-WapNoiseReason {
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)][string] $Reason
    )

    if ($Item.PSObject.Properties['reason']) {
        $Item.reason = $Reason
    }
    else {
        Add-Member -InputObject $Item -MemberType NoteProperty -Name reason -Value $Reason
    }
    return $Item
}

function Set-WapObjectProperty {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)][string] $Name,
        $Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Invoke-WapCaptureFilterApplication {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $captureRoot = Get-WapCaptureSessionPath -Name $Name -RepositoryRoot $RepositoryRoot
    $manifestPath = Join-Path $captureRoot 'output/capture-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Capture manifest not found at '$manifestPath'."
    }
    $manifest = Read-WapCaptureManifest -Name $Name -RepositoryRoot $RepositoryRoot
    $filters = Get-WapCaptureFilters -CaptureRoot $captureRoot -RepositoryRoot $RepositoryRoot

    $allAddedFiles = @(
        (Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $manifest -Name addedFiles)) +
        (Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $manifest -Name addedDirectories)) +
        (Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $manifest -Name filteredAddedFiles))
    )
    $allRegistryChanges = @(
        (Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $manifest -Name changedRegistryKeys)) +
        (Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $manifest -Name filteredRegistryKeys))
    )
    $allUninstallCommands = @(
        (Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $manifest -Name suspectedUninstallCommands)) +
        (Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $manifest -Name filteredUninstallCommands))
    )

    $addedFiles = [System.Collections.ArrayList]::new()
    $addedDirectories = [System.Collections.ArrayList]::new()
    $filteredAddedFiles = [System.Collections.ArrayList]::new()
    $seenAddedPaths = @{}
    foreach ($item in $allAddedFiles) {
        $pathKey = ([string]$item.path).ToLowerInvariant()
        if ($seenAddedPaths.ContainsKey($pathKey)) { continue }
        $seenAddedPaths[$pathKey] = $true
        $reason = Get-WapCaptureNoiseReason -Rules $filters.file -Value ([string]$item.path)
        if ($reason) {
            [void]$filteredAddedFiles.Add((Add-WapNoiseReason -Item $item -Reason $reason))
        }
        elseif ($item.itemType -eq 'Directory') {
            [void]$addedDirectories.Add($item)
        }
        else {
            [void]$addedFiles.Add($item)
        }
    }

    $changedRegistryKeys = [System.Collections.ArrayList]::new()
    $filteredRegistryKeys = [System.Collections.ArrayList]::new()
    foreach ($entry in $allRegistryChanges) {
        $reason = Get-WapCaptureNoiseReason -Rules $filters.registry -Value ([string]$entry.key)
        if ($reason) {
            [void]$filteredRegistryKeys.Add((Add-WapNoiseReason -Item $entry -Reason $reason))
        }
        else {
            [void]$changedRegistryKeys.Add($entry)
        }
    }

    $suspectedUninstallCommands = [System.Collections.ArrayList]::new()
    $filteredUninstallCommands = [System.Collections.ArrayList]::new()
    foreach ($entry in $allUninstallCommands) {
        $reason = Get-WapCaptureUninstallNoiseReason -Rules $filters.uninstall -UninstallCommand $entry
        if ($reason) {
            [void]$filteredUninstallCommands.Add((Add-WapNoiseReason -Item $entry -Reason $reason))
        }
        else {
            [void]$suspectedUninstallCommands.Add($entry)
        }
    }

    Set-WapObjectProperty -Object $manifest -Name addedFiles -Value @($addedFiles.ToArray())
    Set-WapObjectProperty -Object $manifest -Name addedDirectories -Value @($addedDirectories.ToArray())
    Set-WapObjectProperty -Object $manifest -Name filteredAddedFiles -Value @($filteredAddedFiles.ToArray())
    Set-WapObjectProperty -Object $manifest -Name changedRegistryKeys -Value @($changedRegistryKeys.ToArray())
    Set-WapObjectProperty -Object $manifest -Name filteredRegistryKeys -Value @($filteredRegistryKeys.ToArray())
    Set-WapObjectProperty -Object $manifest -Name suspectedUninstallCommands -Value @($suspectedUninstallCommands.ToArray())
    Set-WapObjectProperty -Object $manifest -Name filteredUninstallCommands -Value @($filteredUninstallCommands.ToArray())
    Set-WapObjectProperty -Object $manifest -Name newShortcuts -Value @($addedFiles.ToArray() | Where-Object { $_.path -match '(?i)\.lnk$' })
    Set-WapObjectProperty -Object $manifest -Name filterAppliedAt -Value ((Get-Date).ToUniversalTime().ToString('o'))

    $backupPath = Join-Path (Split-Path -Parent $manifestPath) 'capture-manifest.before-applyfilter.json'
    Copy-Item -LiteralPath $manifestPath -Destination $backupPath -Force
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    Write-Host "Applied capture filters to '$Name'."
    Write-Host "  Manifest: $manifestPath"
    Write-Host "  Backup:   $backupPath"
    Show-WapCaptureDiff -Name $Name -RepositoryRoot $RepositoryRoot
}

function Get-WapCliOption {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Name
    )

    $flag = "--$Name"
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ($Arguments[$index] -eq $flag) {
            if ($index -eq ($Arguments.Count - 1) -or $Arguments[$index + 1].StartsWith('--')) {
                throw "Missing value for '$flag'."
            }
            return $Arguments[$index + 1]
        }
    }
    return $null
}

function Get-WapCliSwitch {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Name
    )

    return $Arguments -contains "--$Name"
}

function Get-WapProfileCaptureRoot {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    if ($ProfileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid profile name '$ProfileName'."
    }
    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $profilePath = Join-Path (Join-Path $config.profilesRoot $ProfileName) 'profile.yaml'
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw "Profile '$ProfileName' was not found at '$profilePath'."
    }
    return Join-Path (Join-Path $config.profilesRoot $ProfileName) 'captures'
}

function Get-WapProfileCaptureId {
    param([Parameter(Mandatory)][string] $Value)

    $id = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $id = $id.Trim('-')
    if ($id -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw "Invalid capture id '$Value'. Use letters, numbers, dots, underscores, and hyphens."
    }
    return $id
}

function Get-WapProfileCaptureMetadataPath {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $root = Get-WapProfileCaptureRoot -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot
    return Join-Path (Join-Path $root (Get-WapProfileCaptureId $CaptureId)) 'metadata.json'
}

function Read-WapProfileCaptureMetadata {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $path = Get-WapProfileCaptureMetadataPath -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Capture '$CaptureId' is not attached to profile '$ProfileName'."
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function ConvertTo-WapIsoTimestampString {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return [string]$Value
}

function Get-WapProfileDefinitionPath {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    if ($ProfileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid profile name '$ProfileName'."
    }
    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $path = Join-Path (Join-Path $config.profilesRoot $ProfileName) 'profile.yaml'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Profile '$ProfileName' was not found at '$path'."
    }
    return $path
}

function ConvertTo-WapYamlScalar {
    param([AllowNull()][string] $Value)

    if ($null -eq $Value) { return "''" }
    if ($Value -match '^[A-Za-z0-9._:/\\${}%-]+$') { return $Value }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Set-WapProfileYamlListSection {
    param(
        [Parameter(Mandatory)][string[]] $Lines,
        [Parameter(Mandatory)][string] $SectionName,
        [Parameter(Mandatory)][string[]] $Replacement
    )

    $start = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match "^$([regex]::Escape($SectionName)):\s*$") {
            $start = $index
            break
        }
    }

    if ($start -lt 0) { return @($Lines + $Replacement) }

    $end = $Lines.Count
    for ($index = $start + 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^[A-Za-z][A-Za-z0-9_-]*:\s*(.*)?$') {
            $end = $index
            break
        }
    }

    $updated = @()
    if ($start -gt 0) { $updated += $Lines[0..($start - 1)] }
    $updated += $Replacement
    if ($end -lt $Lines.Count) { $updated += $Lines[$end..($Lines.Count - 1)] }
    return @($updated)
}

function Set-WapProfileDefinitionLists {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)] $Packages,
        [Parameter(Mandatory)] $Captures
    )

    $path = Get-WapProfileDefinitionPath -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot
    $lines = @(Get-Content -LiteralPath $path)

    $appsReplacement = @('apps:')
    foreach ($package in @($Packages)) {
        $appsReplacement += "  - id: $(ConvertTo-WapYamlScalar ([string]$package.id))"
        $source = if ($package.source) { [string]$package.source } else { 'winget' }
        $appsReplacement += "    source: $(ConvertTo-WapYamlScalar $source)"
        $enabled = if ($package.PSObject.Properties['enabled']) { [bool]$package.enabled } else { $true }
        $appsReplacement += "    enabled: $($enabled.ToString().ToLowerInvariant())"
    }

    $capturesReplacement = @('captures:')
    foreach ($capture in @($Captures)) {
        $capturesReplacement += "  - id: $(ConvertTo-WapYamlScalar ([string]$capture.id))"
        $enabled = if ($capture.PSObject.Properties['enabled']) { [bool]$capture.enabled } else { $true }
        $capturesReplacement += "    enabled: $($enabled.ToString().ToLowerInvariant())"
    }

    $updated = Set-WapProfileYamlListSection -Lines $lines -SectionName 'apps' -Replacement $appsReplacement
    $updated = Set-WapProfileYamlListSection -Lines $updated -SectionName 'captures' -Replacement $capturesReplacement
    $updated | Set-Content -LiteralPath $path -Encoding utf8
}

function Set-WapProfileWingetPackages {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)] $Packages
    )

    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    Set-WapProfileDefinitionLists -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot -Packages $Packages -Captures $profile.captures
}

function Set-WapProfileCaptureReferences {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)] $Captures
    )

    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    Set-WapProfileDefinitionLists -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot -Packages $profile.apps -Captures $Captures
}

function Add-WapProfileWingetPackage {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $PackageId,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $Source = 'winget'
    )

    if ([string]::IsNullOrWhiteSpace($PackageId)) { throw 'Package id is required.' }
    if ([string]::IsNullOrWhiteSpace($Source)) { $Source = 'winget' }
    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    $packages = @($profile.apps)
    if ($packages | Where-Object { $_.id -eq $PackageId -and $_.source -eq $Source }) {
        throw "Profile '$ProfileName' already has winget package '$PackageId' from source '$Source'."
    }
    $packages += [pscustomobject]@{ id = $PackageId; source = $Source; enabled = $true }
    Set-WapProfileWingetPackages -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot -Packages $packages
    Write-Host "Added winget package '$PackageId' to profile '$ProfileName' (source: $Source)."
}

function Set-WapProfileWingetPackageEnabled {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $PackageId,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][bool] $Enabled,
        [string] $Source
    )

    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    $matches = @($profile.apps | Where-Object { $_.id -eq $PackageId -and ((-not $Source) -or $_.source -eq $Source) })
    if (-not $matches.Count) {
        if ($Source) { throw "Profile '$ProfileName' does not have winget package '$PackageId' from source '$Source'." }
        throw "Profile '$ProfileName' does not have winget package '$PackageId'."
    }
    if ($matches.Count -gt 1 -and -not $Source) {
        throw "Profile '$ProfileName' has multiple entries for '$PackageId'. Specify --source."
    }
    $packages = @($profile.apps | ForEach-Object {
        [pscustomobject]@{
            id = $_.id
            source = $_.source
            enabled = if ($_.id -eq $PackageId -and ((-not $Source) -or $_.source -eq $Source)) { $Enabled } else { [bool]$_.enabled }
        }
    })
    Set-WapProfileWingetPackages -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot -Packages $packages
    $stateText = if ($Enabled) { 'enabled' } else { 'disabled' }
    Write-Host "Winget package '$PackageId' is now $stateText on profile '$ProfileName'."
}

function Show-WapProfileWingetPackages {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    $items = @($profile.apps)
    if (-not $items.Count) {
        Write-Host "Profile '$ProfileName' has no winget packages."
        return
    }
    $items | Select-Object id, source, enabled | Format-Table -AutoSize -Wrap
}

function Remove-WapProfileWingetPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $PackageId,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $Source
    )

    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    $matches = @($profile.apps | Where-Object { $_.id -eq $PackageId -and ((-not $Source) -or $_.source -eq $Source) })
    if (-not $matches.Count) {
        if ($Source) { throw "Profile '$ProfileName' does not have winget package '$PackageId' from source '$Source'." }
        throw "Profile '$ProfileName' does not have winget package '$PackageId'."
    }
    if ($matches.Count -gt 1 -and -not $Source) {
        throw "Profile '$ProfileName' has multiple entries for '$PackageId'. Specify --source."
    }

    $packages = @($profile.apps | Where-Object { -not ($_.id -eq $PackageId -and ((-not $Source) -or $_.source -eq $Source)) })
    if ($PSCmdlet.ShouldProcess($PackageId, "Remove winget package from profile '$ProfileName'")) {
        Set-WapProfileWingetPackages -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot -Packages $packages
        $sourceText = if ($Source) { " from source '$Source'" } else { '' }
        Write-Host "Removed winget package '$PackageId'$sourceText from profile '$ProfileName'."
    }
}

function Show-WapProfile {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    $state = Get-WapState $RepositoryRoot
    $profileState = Get-WapProfileState $state $ProfileName
    $installed = $profileState -and [bool]$profileState.installed
    $active = $installed -and $state.activeProfile -eq $ProfileName

    Write-Host "Profile:        $ProfileName"
    Write-Host "Status:         $(if ($active) { 'Active' } elseif ($installed) { 'Installed' } else { 'Not installed' })"
    Write-Host "Definition:     $($profile.source)"
    Write-Host "Profile root:   $($profile.profileRoot)"
    Write-Host "Shared root:    $($profile.sharedRoot)"
    Write-Host ''
    Write-Host "Winget packages: $($profile.apps.Count)"
    if ($profile.apps.Count) { $profile.apps | Select-Object id, source, enabled | Format-Table -AutoSize -Wrap }
    Write-Host ''
    $capturePlan = @(Get-WapProfileCapturePlan -Name $ProfileName -RepositoryRoot $RepositoryRoot)
    Write-Host "Attached captures: $($capturePlan.Count)"
    if ($capturePlan.Count) { $capturePlan | Select-Object id, name, enabled, selectedVersion | Format-Table -AutoSize -Wrap }
    $unreferenced = @(Get-WapProfileUnreferencedCaptures -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot)
    if ($unreferenced.Count) {
        Write-Host ''
        Write-Host "Unreferenced capture folders: $($unreferenced.Count)"
        $unreferenced | Select-Object id, name, selectedVersion | Format-Table -AutoSize -Wrap
        Write-WapUnreferencedCaptureGuidance -ProfileName $ProfileName -Captures $unreferenced
    }
}

function Write-WapUnreferencedCaptureGuidance {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)] $Captures
    )

    Write-Host ''
    Write-Host 'To add unreferenced captures to profile.yaml and enable them, run:'
    foreach ($capture in @($Captures)) {
        Write-Host "  .\wap.ps1 profile capture enable $ProfileName $($capture.id)"
    }
}

function Add-WapProfileCapture {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureName,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $CaptureId,
        [string] $DisplayName,
        [string] $Description
    )

    $captureRoot = Get-WapCaptureSessionPath -Name $CaptureName -RepositoryRoot $RepositoryRoot
    $manifestPath = Join-Path $captureRoot 'output/capture-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Capture manifest not found at '$manifestPath'. Run C:\WAPCapture\Capture-Finalize.ps1 in Sandbox first, then 'capture validate'."
    }
    $manifest = Read-WapCaptureManifest -Name $CaptureName -RepositoryRoot $RepositoryRoot
    if ($manifest.safety.destructiveActionsPerformed -ne $false -or
        $manifest.safety.msixGenerated -ne $false) {
        throw 'Capture manifest does not declare the required dry-run safety state.'
    }

    $idSource = if ($CaptureId) { $CaptureId } else { $CaptureName }
    $id = Get-WapProfileCaptureId $idSource
    $capturesRoot = Get-WapProfileCaptureRoot -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot
    $targetRoot = Join-Path $capturesRoot $id
    if (Test-Path -LiteralPath $targetRoot) {
        throw "Profile '$ProfileName' already has a capture with id '$id'."
    }
    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    $references = @($profile.captures)
    if ($references | Where-Object { $_.id -eq $id }) {
        throw "Profile '$ProfileName' already references capture '$id' in profile.yaml."
    }

    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $targetRoot 'capture-manifest.json')
    $filterPath = Join-Path $captureRoot 'capture-filters.json'
    if (Test-Path -LiteralPath $filterPath -PathType Leaf) {
        Copy-Item -LiteralPath $filterPath -Destination (Join-Path $targetRoot 'capture-filters.json')
    }

    $sessionPath = Join-Path $captureRoot 'session.json'
    $session = if (Test-Path -LiteralPath $sessionPath -PathType Leaf) {
        Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    }
    else { $null }
    $createdAt = if ($session -and $session.PSObject.Properties['createdAt']) { $session.createdAt } else { $manifest.capturedAt }
    $createdAt = ConvertTo-WapIsoTimestampString $createdAt
    $addedAt = (Get-Date).ToUniversalTime().ToString('o')
    [ordered]@{
        id = $id
        name = if ($DisplayName) { $DisplayName } else { $id }
        description = if ($Description) { $Description } else { '' }
        createdAt = $createdAt
        addedAt = $addedAt
        updatedAt = $addedAt
        sourceCapture = $CaptureName
        sourceCapturePath = $captureRoot
        manifest = 'capture-manifest.json'
        selectedVersion = 'base'
        versions = @()
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $targetRoot 'metadata.json') -Encoding UTF8

    $references += [pscustomobject]@{ id = $id; enabled = $true }
    $packages = @($profile.apps)
    $addedPackages = @()
    foreach ($package in @(Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $manifest -Name newWingetPackages))) {
        $packageId = if ($package -is [string]) { [string]$package } else { [string]$package.id }
        if ([string]::IsNullOrWhiteSpace($packageId)) { continue }
        $source = if ($package -isnot [string] -and $package.PSObject.Properties['source'] -and
            -not [string]::IsNullOrWhiteSpace([string]$package.source)) {
            [string]$package.source
        }
        else { 'winget' }
        if ($packages | Where-Object { $_.id -eq $packageId -and $_.source -eq $source }) { continue }
        $packages += [pscustomobject]@{
            id = $packageId
            source = $source
            enabled = $true
        }
        $addedPackages += "$packageId (source: $source)"
    }
    Set-WapProfileDefinitionLists -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot -Packages $packages -Captures $references
    Write-Host "Added capture '$id' to profile '$ProfileName'."
    foreach ($package in $addedPackages) {
        Write-Host "Added Sandbox-detected winget package '$package' to profile '$ProfileName'."
    }
}

function Get-WapProfileUnreferencedCaptures {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    $referencedIds = @($profile.captures | ForEach-Object { [string]$_.id })
    $root = Get-WapProfileCaptureRoot -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'metadata.json')) -and
                ($referencedIds -notcontains $_.Name)
            } |
            ForEach-Object { Get-Content -LiteralPath (Join-Path $_.FullName 'metadata.json') -Raw | ConvertFrom-Json } |
            Sort-Object id
    )
}

function Show-WapProfileCaptures {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $items = @(Get-WapProfileCapturePlan -Name $ProfileName -RepositoryRoot $RepositoryRoot)
    $unreferenced = @(Get-WapProfileUnreferencedCaptures -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot)
    if (-not $items.Count) {
        Write-Host "Profile '$ProfileName' has no referenced captures."
    }
    else {
        Write-Host "Referenced captures:"
        $items | Sort-Object id | Select-Object id, name, enabled, selectedVersion | Format-Table -AutoSize -Wrap
    }
    if ($unreferenced.Count) {
        Write-Host ''
        Write-Host 'Unreferenced capture folders:'
        $unreferenced | Select-Object id, name, selectedVersion, createdAt, addedAt, description | Format-Table -AutoSize -Wrap
        Write-WapUnreferencedCaptureGuidance -ProfileName $ProfileName -Captures $unreferenced
    }
}

function Set-WapProfileCaptureEnabled {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][bool] $Enabled
    )

    $id = Get-WapProfileCaptureId $CaptureId
    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    if (-not (@($profile.captures) | Where-Object { $_.id -eq $id })) {
        if ($Enabled) {
            Add-WapProfileCaptureReference -ProfileName $ProfileName -CaptureId $id -RepositoryRoot $RepositoryRoot -Enabled $true
            return
        }
        throw "Profile '$ProfileName' does not reference capture '$id' in profile.yaml. Use 'profile capture enable' to add and enable it first."
    }
    $references = @($profile.captures | ForEach-Object {
        [pscustomobject]@{
            id = $_.id
            enabled = if ($_.id -eq $id) { $Enabled } else { [bool]$_.enabled }
        }
    })
    Set-WapProfileCaptureReferences -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot -Captures $references
    $stateText = if ($Enabled) { 'enabled' } else { 'disabled' }
    Write-Host "Capture '$id' is now $stateText on profile '$ProfileName'."
}

function Add-WapProfileCaptureReference {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [bool] $Enabled = $true
    )

    $id = Get-WapProfileCaptureId $CaptureId
    $root = Get-WapProfileCaptureRoot -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot
    $captureRoot = Join-Path $root $id
    $metadataPath = Join-Path $captureRoot 'metadata.json'
    $manifestPath = Join-Path $captureRoot 'capture-manifest.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Capture folder '$captureRoot' does not contain metadata.json."
    }
    if ($Enabled -and -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Capture '$id' cannot be enabled because '$manifestPath' was not found."
    }
    $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
    if (@($profile.captures) | Where-Object { $_.id -eq $id }) {
        throw "Profile '$ProfileName' already references capture '$id' in profile.yaml."
    }
    $references = @($profile.captures)
    $references += [pscustomobject]@{ id = $id; enabled = $Enabled }
    Set-WapProfileCaptureReferences -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot -Captures $references
    $stateText = if ($Enabled) { 'enabled' } else { 'disabled' }
    Write-Host "Capture '$id' was added to profile.yaml and is now $stateText on profile '$ProfileName'."
}

function Remove-WapProfileCapture {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $root = Get-WapProfileCaptureRoot -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot
    $id = Get-WapProfileCaptureId $CaptureId
    $path = Join-Path $root $id
    if (-not (Test-Path -LiteralPath (Join-Path $path 'metadata.json') -PathType Leaf)) {
        throw "Capture '$id' is not attached to profile '$ProfileName'."
    }
    if ($PSCmdlet.ShouldProcess($path, 'Remove profile capture')) {
        Remove-Item -LiteralPath $path -Recurse -Force
        $profile = Import-WapProfile -Name $ProfileName -RepositoryRoot $RepositoryRoot
        $references = @($profile.captures | Where-Object { $_.id -ne $id })
        Set-WapProfileCaptureReferences -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot -Captures $references
        Write-Host "Removed capture '$id' from profile '$ProfileName'."
    }
}

function Copy-WapProfileCapture {
    param(
        [Parameter(Mandatory)][string] $FromProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $ToProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $NewCaptureId,
        [string] $DisplayName,
        [string] $Description
    )

    $sourceRoot = Get-WapProfileCaptureRoot -ProfileName $FromProfileName -RepositoryRoot $RepositoryRoot
    $sourceId = Get-WapProfileCaptureId $CaptureId
    $sourcePath = Join-Path $sourceRoot $sourceId
    if (-not (Test-Path -LiteralPath (Join-Path $sourcePath 'metadata.json') -PathType Leaf)) {
        throw "Capture '$sourceId' is not attached to profile '$FromProfileName'."
    }

    $targetRoot = Get-WapProfileCaptureRoot -ProfileName $ToProfileName -RepositoryRoot $RepositoryRoot
    $targetIdSource = if ($NewCaptureId) { $NewCaptureId } else { $sourceId }
    $targetId = Get-WapProfileCaptureId $targetIdSource
    $targetPath = Join-Path $targetRoot $targetId
    if (Test-Path -LiteralPath $targetPath) {
        throw "Profile '$ToProfileName' already has a capture with id '$targetId'."
    }
    $targetProfile = Import-WapProfile -Name $ToProfileName -RepositoryRoot $RepositoryRoot
    $references = @($targetProfile.captures)
    if ($references | Where-Object { $_.id -eq $targetId }) {
        throw "Profile '$ToProfileName' already references capture '$targetId' in profile.yaml."
    }
    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    Get-ChildItem -LiteralPath $sourcePath -Force | Copy-Item -Destination $targetPath -Recurse -Force
    $metadataPath = Join-Path $targetPath 'metadata.json'
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $metadata.id = $targetId
    if ($DisplayName) { $metadata.name = $DisplayName }
    if ($Description) { $metadata.description = $Description }
    $metadata.addedAt = (Get-Date).ToUniversalTime().ToString('o')
    Set-WapObjectProperty -Object $metadata -Name copiedFromProfile -Value $FromProfileName
    Set-WapObjectProperty -Object $metadata -Name copiedFromCaptureId -Value $sourceId
    $metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    $references += [pscustomobject]@{ id = $targetId; enabled = $true }
    Set-WapProfileCaptureReferences -ProfileName $ToProfileName -RepositoryRoot $RepositoryRoot -Captures $references
    Write-Host "Copied capture '$sourceId' from profile '$FromProfileName' to '$ToProfileName' as '$targetId'."
}

function Edit-WapProfileCapture {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $DisplayName,
        [string] $Description
    )

    if (-not $DisplayName -and $null -eq $Description) {
        throw "Nothing to edit. Use --name and/or --description."
    }
    $metadataPath = Get-WapProfileCaptureMetadataPath -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    $metadata = Read-WapProfileCaptureMetadata -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    if ($DisplayName) { $metadata.name = $DisplayName }
    if ($null -ne $Description) { $metadata.description = $Description }
    Set-WapObjectProperty -Object $metadata -Name updatedAt -Value ((Get-Date).ToUniversalTime().ToString('o'))
    $metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    Write-Host "Updated capture '$CaptureId' on profile '$ProfileName'."
}

function Get-WapProfileCapturePath {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $root = Get-WapProfileCaptureRoot -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot
    $id = Get-WapProfileCaptureId $CaptureId
    $path = Join-Path $root $id
    if (-not (Test-Path -LiteralPath (Join-Path $path 'metadata.json') -PathType Leaf)) {
        throw "Capture '$id' is not attached to profile '$ProfileName'."
    }
    return $path
}

function Get-WapCaptureVersionFields {
    return @(
        'addedFiles',
        'addedDirectories',
        'changedFiles',
        'changedRegistryKeys',
        'newServices',
        'newScheduledTasks',
        'newShortcuts',
        'suspectedUninstallCommands',
        'filteredAddedFiles',
        'filteredRegistryKeys',
        'filteredUninstallCommands'
    )
}

function Get-WapCaptureItemIdentity {
    param($Item)

    foreach ($propertyName in @('path', 'key', 'Name', 'TaskName', 'command', 'registryKey')) {
        $value = Get-WapObjectProperty -Object $Item -Name $propertyName
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return "$propertyName=$([string]$value)".ToLowerInvariant()
        }
    }
    return ($Item | ConvertTo-Json -Depth 12 -Compress).ToLowerInvariant()
}

function Merge-WapCaptureManifestArray {
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)][string] $FieldName,
        $Items
    )

    $existing = [System.Collections.ArrayList]::new()
    $seen = @{}
    foreach ($item in @(Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $Manifest -Name $FieldName))) {
        $identity = Get-WapCaptureItemIdentity -Item $item
        if (-not $seen.ContainsKey($identity)) {
            $seen[$identity] = $true
            [void]$existing.Add($item)
        }
    }
    foreach ($item in @(Read-WapCaptureJsonItems $Items)) {
        $identity = Get-WapCaptureItemIdentity -Item $item
        if (-not $seen.ContainsKey($identity)) {
            $seen[$identity] = $true
            [void]$existing.Add($item)
        }
    }
    Set-WapObjectProperty -Object $Manifest -Name $FieldName -Value @($existing.ToArray())
}

function Get-WapEffectiveProfileCaptureManifest {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $UpToVersion
    )

    $capturePath = Get-WapProfileCapturePath -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    $manifestPath = Join-Path $capturePath 'capture-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $metadata = Read-WapProfileCaptureMetadata -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    $targetVersion = if ($UpToVersion) { $UpToVersion } elseif ($metadata.PSObject.Properties['selectedVersion']) { [string]$metadata.selectedVersion } else { 'base' }
    if ($targetVersion -eq 'base') { return $manifest }

    $versions = @($metadata.versions | Where-Object { $null -ne $_ } | Sort-Object version)
    foreach ($version in $versions) {
        $deltaPath = Join-Path $capturePath ([string]$version.delta)
        if (-not (Test-Path -LiteralPath $deltaPath -PathType Leaf)) {
            throw "Capture version delta '$deltaPath' was not found."
        }
        $delta = Get-Content -LiteralPath $deltaPath -Raw | ConvertFrom-Json
        foreach ($field in (Get-WapCaptureVersionFields)) {
            Merge-WapCaptureManifestArray -Manifest $manifest -FieldName $field -Items (Get-WapObjectProperty -Object $delta -Name $field)
        }
        if ([string]$version.version -eq $targetVersion) { return $manifest }
    }
    throw "Version '$targetVersion' was not found for capture '$CaptureId' on profile '$ProfileName'."
}

function New-WapCaptureDelta {
    param(
        [Parameter(Mandatory)] $CurrentManifest,
        [Parameter(Mandatory)] $NewManifest
    )

    $delta = [ordered]@{
        version = 1
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    foreach ($field in (Get-WapCaptureVersionFields)) {
        $currentIds = @{}
        foreach ($item in @(Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $CurrentManifest -Name $field))) {
            $currentIds[(Get-WapCaptureItemIdentity -Item $item)] = $true
        }
        $added = @(
            Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $NewManifest -Name $field) |
                Where-Object { -not $currentIds.ContainsKey((Get-WapCaptureItemIdentity -Item $_)) }
        )
        $delta[$field] = @($added)
    }
    return [pscustomobject]$delta
}

function Get-WapNextCaptureVersion {
    param($Metadata)

    $max = 0
    foreach ($version in @($Metadata.versions | Where-Object { $null -ne $_ })) {
        if ([string]$version.version -match '^v(\d+)$') {
            $number = [int]$Matches[1]
            if ($number -gt $max) { $max = $number }
        }
    }
    return ('v{0:0000}' -f ($max + 1))
}

function Update-WapProfileCaptureMetadata {
    param(
        [Parameter(Mandatory)][string] $CapturePath,
        [Parameter(Mandatory)] $Metadata
    )

    Set-WapObjectProperty -Object $Metadata -Name updatedAt -Value ((Get-Date).ToUniversalTime().ToString('o'))
    $Metadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $CapturePath 'metadata.json') -Encoding UTF8
}

function Refresh-WapProfileCapture {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $CaptureName,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $Description,
        [switch] $Apply
    )

    $capturePath = Get-WapProfileCapturePath -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    $metadata = Read-WapProfileCaptureMetadata -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    if (-not $metadata.PSObject.Properties['versions']) { Set-WapObjectProperty -Object $metadata -Name versions -Value @() }
    if (-not $metadata.PSObject.Properties['selectedVersion']) { Set-WapObjectProperty -Object $metadata -Name selectedVersion -Value 'base' }

    $newManifest = Read-WapCaptureManifest -Name $CaptureName -RepositoryRoot $RepositoryRoot
    $currentManifest = Get-WapEffectiveProfileCaptureManifest -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    $delta = New-WapCaptureDelta -CurrentManifest $currentManifest -NewManifest $newManifest
    $newVersion = Get-WapNextCaptureVersion -Metadata $metadata
    Set-WapObjectProperty -Object $delta -Name profileName -Value $ProfileName
    Set-WapObjectProperty -Object $delta -Name captureId -Value (Get-WapProfileCaptureId $CaptureId)
    Set-WapObjectProperty -Object $delta -Name sourceCapture -Value $CaptureName
    Set-WapObjectProperty -Object $delta -Name version -Value $newVersion
    if ($Description) { Set-WapObjectProperty -Object $delta -Name description -Value $Description }

    $versionRoot = Join-Path $capturePath "versions/$newVersion"
    New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
    $deltaPath = Join-Path $versionRoot 'capture-delta.json'
    $delta | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $deltaPath -Encoding UTF8

    $versionEntry = [ordered]@{
        version = $newVersion
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
        sourceCapture = $CaptureName
        description = if ($Description) { $Description } else { '' }
        delta = "versions/$newVersion/capture-delta.json"
    }
    $versions = @($metadata.versions | Where-Object { $null -ne $_ }) + @([pscustomobject]$versionEntry)
    Set-WapObjectProperty -Object $metadata -Name versions -Value @($versions)
    if ($Apply) { Set-WapObjectProperty -Object $metadata -Name selectedVersion -Value $newVersion }
    Update-WapProfileCaptureMetadata -CapturePath $capturePath -Metadata $metadata

    Write-Host "Added refresh version '$newVersion' to capture '$CaptureId' on profile '$ProfileName'."
    if ($Apply) { Write-Host "Selected version is now '$newVersion'." }
    foreach ($field in (Get-WapCaptureVersionFields)) {
        $count = @(Read-WapCaptureJsonItems (Get-WapObjectProperty -Object $delta -Name $field)).Count
        if ($count) { Write-Host ("  {0}: {1}" -f $field, $count) }
    }
}

function Show-WapProfileCaptureVersions {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $metadata = Read-WapProfileCaptureMetadata -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    Write-Host "Capture '$CaptureId' on profile '$ProfileName'"
    Write-Host "Selected version: $(if ($metadata.PSObject.Properties['selectedVersion']) { $metadata.selectedVersion } else { 'base' })"
    $versions = @($metadata.versions | Where-Object { $null -ne $_ } | Sort-Object version)
    if (-not $versions.Count) {
        Write-Host 'No refresh versions. Base manifest only.'
        return
    }
    $versions | Select-Object version, createdAt, sourceCapture, description | Format-Table -AutoSize -Wrap
}

function Select-WapProfileCaptureVersion {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $capturePath = Get-WapProfileCapturePath -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    $metadata = Read-WapProfileCaptureMetadata -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    $selected = if ($Version -eq 'latest') {
        $latest = @($metadata.versions | Where-Object { $null -ne $_ } | Sort-Object version | Select-Object -Last 1)
        if (-not $latest) { 'base' } else { [string]$latest.version }
    }
    else { $Version }
    if ($selected -ne 'base' -and -not (@($metadata.versions | Where-Object { $_.version -eq $selected }).Count)) {
        throw "Version '$selected' was not found for capture '$CaptureId'."
    }
    Set-WapObjectProperty -Object $metadata -Name selectedVersion -Value $selected
    Update-WapProfileCaptureMetadata -CapturePath $capturePath -Metadata $metadata
    Write-Host "Selected version '$selected' for capture '$CaptureId' on profile '$ProfileName'."
}

function Merge-WapProfileCaptureVersions {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $CaptureId,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $UpToVersion
    )

    $capturePath = Get-WapProfileCapturePath -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    $metadata = Read-WapProfileCaptureMetadata -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot
    $target = if ($UpToVersion) { $UpToVersion } elseif ($metadata.PSObject.Properties['selectedVersion']) { [string]$metadata.selectedVersion } else { 'base' }
    if ($target -eq 'base') {
        Write-Host "Capture '$CaptureId' is already at base; nothing to merge."
        return
    }
    $effective = Get-WapEffectiveProfileCaptureManifest -ProfileName $ProfileName -CaptureId $CaptureId -RepositoryRoot $RepositoryRoot -UpToVersion $target
    $manifestPath = Join-Path $capturePath 'capture-manifest.json'
    $backupPath = Join-Path $capturePath ("capture-manifest.before-merge-{0}.json" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    Copy-Item -LiteralPath $manifestPath -Destination $backupPath
    Set-WapObjectProperty -Object $effective -Name mergedAt -Value ((Get-Date).ToUniversalTime().ToString('o'))
    Set-WapObjectProperty -Object $effective -Name mergedThroughVersion -Value $target
    $effective | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $remaining = @($metadata.versions | Where-Object { $_.version -gt $target })
    Set-WapObjectProperty -Object $metadata -Name versions -Value @($remaining)
    Set-WapObjectProperty -Object $metadata -Name selectedVersion -Value 'base'
    Set-WapObjectProperty -Object $metadata -Name lastMergedVersion -Value $target
    Update-WapProfileCaptureMetadata -CapturePath $capturePath -Metadata $metadata
    Write-Host "Merged capture '$CaptureId' through version '$target'."
    Write-Host "Backup: $backupPath"
}

function Show-WapCaptureDiff {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $manifest = Read-WapCaptureManifest -Name $Name -RepositoryRoot $RepositoryRoot
    $addedFiles = @($manifest.addedFiles | Where-Object { $null -ne $_ })
    $hasFilteredFiles = $null -ne $manifest.PSObject.Properties['filteredAddedFiles']
    $filteredFiles = @(if ($hasFilteredFiles) {
        @($manifest.filteredAddedFiles | Where-Object { $null -ne $_ })
    }
    else { @() })
    $changedRegistry = @($manifest.changedRegistryKeys | Where-Object { $null -ne $_ })
    $hasFilteredRegistry = $null -ne $manifest.PSObject.Properties['filteredRegistryKeys']
    $filteredRegistry = @(if ($hasFilteredRegistry) {
        @($manifest.filteredRegistryKeys | Where-Object { $null -ne $_ })
    }
    else { @() })
    $newServices = @($manifest.newServices | Where-Object { $null -ne $_ })
    $newShortcuts = @($manifest.newShortcuts | Where-Object { $null -ne $_ })
    $uninstallCommands = @($manifest.suspectedUninstallCommands | Where-Object { $null -ne $_ })
    $hasFilteredUninstallCommands = $null -ne $manifest.PSObject.Properties['filteredUninstallCommands']
    $filteredUninstallCommands = @(if ($hasFilteredUninstallCommands) {
        @($manifest.filteredUninstallCommands | Where-Object { $null -ne $_ })
    }
    else { @() })

    Write-Host "Capture diff for '$Name'"
    Write-Host "  Added files:                  $($addedFiles.Count)"
    if ($hasFilteredFiles) {
        Write-Host "  Filtered file noise:          $($filteredFiles.Count)"
    }
    Write-Host "  Changed registry keys:        $($changedRegistry.Count)"
    if ($hasFilteredRegistry) {
        Write-Host "  Filtered registry noise:      $($filteredRegistry.Count)"
    }
    Write-Host "  New services:                 $($newServices.Count)"
    Write-Host "  New shortcuts:                $($newShortcuts.Count)"
    Write-Host "  Suspected uninstall commands: $($uninstallCommands.Count)"
    if ($hasFilteredUninstallCommands) {
        Write-Host "  Filtered uninstall noise:     $($filteredUninstallCommands.Count)"
    }
    Write-Host '  Safety: dry-run evidence only; nothing was deleted and no MSIX was generated.'

    if ($addedFiles.Count) {
        Write-Host "`nAdded files (first 15):"
        $addedFiles | Select-Object -First 15 scope, path | Format-Table -AutoSize
    }
    if ($changedRegistry.Count) {
        Write-Host "`nChanged registry keys (first 15):"
        $changedRegistry | Select-Object -First 15 change, hive, key | Format-Table -AutoSize
    }
    if ($newServices.Count) {
        Write-Host "`nNew services:"
        $newServices | Select-Object Name, DisplayName, StartMode, PathName | Format-Table -AutoSize
    }
    if ($newShortcuts.Count) {
        Write-Host "`nNew shortcuts:"
        $newShortcuts | Select-Object scope, path | Format-Table -AutoSize
    }
    if ($uninstallCommands.Count) {
        Write-Host "`nSuspected uninstall commands:"
        $uninstallCommands | Select-Object source, command | Format-Table -AutoSize -Wrap
    }
}

function Test-WapInteractiveCapture {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $manifest = Read-WapCaptureManifest -Name $Name -RepositoryRoot $RepositoryRoot
    if ($manifest.safety.destructiveActionsPerformed -ne $false -or
        $manifest.safety.msixGenerated -ne $false) {
        throw 'Capture manifest does not declare the required dry-run safety state.'
    }
    Write-Host "Capture '$Name' manifest validated."
    Show-WapCaptureDiff -Name $Name -RepositoryRoot $RepositoryRoot
}

function Remove-WapCaptureSession {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $captureRoot = Get-WapCaptureSessionPath -Name $Name -RepositoryRoot $RepositoryRoot
    $capturesRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot '.capture'))
    $capturePath = [IO.Path]::GetFullPath($captureRoot)
    if ([IO.Path]::GetDirectoryName($capturePath) -ne $capturesRoot) {
        throw "Refusing to delete a path outside '$capturesRoot'."
    }
    if (-not (Test-Path -LiteralPath $capturePath -PathType Container)) {
        throw "Capture session '$Name' was not found at '$capturePath'."
    }

    Write-Host "Deleting capture session '$Name'..."
    Write-Host "  [delete] $capturePath"
    Write-Host '  [keep] Profile definitions, workspace data, and WAP state are not touched.'
    if ($PSCmdlet.ShouldProcess($capturePath, 'Delete capture session directory')) {
        Remove-Item -LiteralPath $capturePath -Recurse -Force
        Write-Host "Done: capture session '$Name' deleted."
    }
}

function Remove-WapProfileDefinition {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid profile name '$Name'."
    }
    $state = Get-WapState -RepositoryRoot $RepositoryRoot
    if ($state.activeProfile -eq $Name -or $state.profiles.Contains($Name)) {
        throw "Profile '$Name' is installed or active. Uninstall it before deleting its definition."
    }

    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $profilesRoot = [IO.Path]::GetFullPath($config.profilesRoot)
    $profilePath = [IO.Path]::GetFullPath((Join-Path $profilesRoot $Name))
    if ([IO.Path]::GetDirectoryName($profilePath) -ne $profilesRoot) {
        throw "Refusing to delete a path outside '$profilesRoot'."
    }
    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
        throw "Profile definition '$Name' was not found at '$profilePath'."
    }

    Write-Host "Deleting profile definition '$Name'..."
    Write-Host "  [delete] $profilePath"
    Write-Host '  [keep] Workspace data and capture history are not touched.'
    if ($PSCmdlet.ShouldProcess($profilePath, 'Delete profile definition directory')) {
        Remove-Item -LiteralPath $profilePath -Recurse -Force
        Write-Host "Done: profile definition '$Name' deleted."
    }
}

function New-WapProfileDefinition {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid profile name '$Name'. Use letters, numbers, dots, underscores, and hyphens."
    }

    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $profilesRoot = [IO.Path]::GetFullPath($config.profilesRoot)
    $profileDirectory = [IO.Path]::GetFullPath((Join-Path $profilesRoot $Name))
    if ([IO.Path]::GetDirectoryName($profileDirectory) -ne $profilesRoot) {
        throw "Refusing to create a path outside '$profilesRoot'."
    }

    $profilePath = Join-Path $profileDirectory 'profile.yaml'
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        throw "Profile '$Name' already exists at '$profilePath'."
    }
    $existingItems = @()
    $profileDirectoryExists = Test-Path -LiteralPath $profileDirectory -PathType Container
    if ($profileDirectoryExists) {
        $existingItems = @(Get-ChildItem -LiteralPath $profileDirectory -Force -ErrorAction SilentlyContinue)
    }
    if ($profileDirectoryExists -and $existingItems.Count) {
        throw "Profile directory '$profileDirectory' already exists and is not empty."
    }

    $lines = @(
        "# Created $(Get-Date -Format o)"
        "# WindowsAutoProfiles profile"
        "name: $Name"
        'apps:'
        '  # - id: Git.Git'
        '  #   source: winget'
        'env:'
        "  WAP_PROFILE: $Name"
        'path:'
        '  # - ${profileRoot}\Apps\bin'
        'projects: ${profileRoot}\Projects'
        'data: ${profileRoot}\Data'
        'downloads: ${profileRoot}\Downloads'
        'cache: ${profileRoot}\Cache'
        'shortcuts:'
        '  # - name: Example'
        '  #   target: ${profileRoot}\Apps\Example.exe'
    )

    if ($PSCmdlet.ShouldProcess($profilePath, 'Create empty profile definition')) {
        New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
        $lines | Set-Content -LiteralPath $profilePath -Encoding utf8
        Write-Host "Created profile '$Name' at '$profilePath'."
        Write-Host "Edit it, then install it with:"
        Write-Host "  .\wap.ps1 profile install $Name"
    }
}

function New-WapCapture {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid profile name '$Name'." }
    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $directory = Join-Path $config.profilesRoot $Name
    $path = Join-Path $directory 'profile.yaml'
    if (Test-Path -LiteralPath $path) { throw "Profile '$Name' already exists." }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $lines = @(
        "# Captured $(Get-Date -Format o)"
        "name: $Name"
        'apps:'
    )
    $lines += '  # Add packages explicitly with: .\wap.ps1 profile winget add <profile> <packageId>'
    $lines += @(
        'env:'
        "  WAP_PROFILE: $Name"
        'path:'
        '  - ${profileRoot}\Apps\bin'
        'projects: ${profileRoot}\Projects'
        'data: ${profileRoot}\Data'
        'downloads: ${profileRoot}\Downloads'
        'cache: ${profileRoot}\Cache'
        'shortcuts:'
        '  # - name: Example'
        '  #   target: ${profileRoot}\Apps\Example.exe'
    )
    $lines | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "Captured profile '$Name' at '$path'. Review it before installation."
}

function Initialize-Wap {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [switch] $SkipPrereqs
    )

    foreach ($directory in @('profiles', 'docs')) {
        New-Item -ItemType Directory -Path (Join-Path $RepositoryRoot $directory) -Force | Out-Null
    }
    $configPath = Join-Path $RepositoryRoot 'wap.config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        [ordered]@{
            version = 1
            configPath = 'wap.settings.json'
        } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
    }
    $fullConfigPath = Join-Path $RepositoryRoot 'wap.settings.json'
    if (-not (Test-Path -LiteralPath $fullConfigPath)) {
        [ordered]@{
            version = 1
            workspaceRoot = '%USERPROFILE%\Workspaces'
            profilesRoot = 'profiles'
            logging = [ordered]@{
                enabled = $true
                retentionDays = 30
                root = '.logs'
            }
            sandbox = [ordered]@{
                installWinget = $true
            }
        } | ConvertTo-Json | Set-Content -LiteralPath $fullConfigPath -Encoding utf8
    }

    $statePath = Join-Path $RepositoryRoot '.wap-state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        Save-WapState (New-WapState) $RepositoryRoot
    }
    Write-Host "WindowsAutoProfiles initialized at '$RepositoryRoot'."
    if (-not $SkipPrereqs) {
        Install-WapPrerequisites -WhatIf:$WhatIfPreference
    }
}

function Show-WapHelp {
    @'
WindowsAutoProfiles
Version: 1.1
Last updated: 2026-07-04T05:18:20Z
Author: Michal Zygmunt <lahcim@fajne.com>
Minimum PowerShell: 5.1

Usage:
  .\wap.ps1 --help
  .\wap.ps1 --examples
  .\wap.ps1 init [--skip-prereqs] [-WhatIf]
  .\wap.ps1 config show
  .\wap.ps1 config set bootstrapConfigPath <path> [-WhatIf]
  .\wap.ps1 config set configPath <path> [-WhatIf]
  .\wap.ps1 config set workspaceRoot <path> [-WhatIf]
  .\wap.ps1 config set profilesRoot <path> [-WhatIf]
  .\wap.ps1 config set logging.enabled <true|false> [-WhatIf]
  .\wap.ps1 config set logging.retentionDays <days> [-WhatIf]
  .\wap.ps1 config set logging.root <path> [-WhatIf]
  .\wap.ps1 config set sandbox.installWinget <true|false> [-WhatIf]
  .\wap.ps1 logs cleanup [-WhatIf]
  .\wap.ps1 profile install <name> [--sandbox] [-WhatIf]
  .\wap.ps1 profile uninstall <name> [--remove-user-data] [--remove-registry] [-WhatIf]
  .\wap.ps1 profile cleanup <name> [--user-data] [--registry] [--all] [-WhatIf]
  .\wap.ps1 profile new <name> [-WhatIf]
  .\wap.ps1 profile activate <name> [-WhatIf]
  .\wap.ps1 profile deactivate <name> [-WhatIf]
  .\wap.ps1 profile delete <name> [-WhatIf]
  .\wap.ps1 profile status
  .\wap.ps1 profile list
  .\wap.ps1 profile show <name>
  .\wap.ps1 profile winget add <profile> <packageId> [--source <source>]
  .\wap.ps1 profile winget list <profile>
  .\wap.ps1 profile winget enable <profile> <packageId> [--source <source>]
  .\wap.ps1 profile winget disable <profile> <packageId> [--source <source>]
  .\wap.ps1 profile winget remove <profile> <packageId> [--source <source>] [-WhatIf]

  .\wap.ps1 profile capture add <profile> <capture> [--id <id>] [--name <name>] [--description <text>]
  .\wap.ps1 profile capture list <profile>
  .\wap.ps1 profile capture enable <profile> <captureId>
  .\wap.ps1 profile capture disable <profile> <captureId>
  .\wap.ps1 profile capture remove <profile> <captureId> [-WhatIf]
  .\wap.ps1 profile capture copy <fromProfile> <captureId> <toProfile> [--id <id>] [--name <name>] [--description <text>]
  .\wap.ps1 profile capture edit <profile> <captureId> [--name <name>] [--description <text>]
  .\wap.ps1 profile capture refresh <profile> <captureId> <capture> [--description <text>] [--apply]
  .\wap.ps1 profile capture versions <profile> <captureId>
  .\wap.ps1 profile capture select-version <profile> <captureId> <base|latest|version>
  .\wap.ps1 profile capture merge <profile> <captureId> [--up-to <version>]
  .\wap.ps1 capture new <name>
  .\wap.ps1 capture start <name> [--no-winget] [-WhatIf]
  .\wap.ps1 capture list
  .\wap.ps1 capture rename <name> <newName> [-WhatIf]
  .\wap.ps1 capture validate <name>
  .\wap.ps1 capture diff <name>
  .\wap.ps1 capture applyfilter <name>
  .\wap.ps1 capture remove <name> [-WhatIf]

Global options:
  --examples  Show step-by-step populated examples from docs\examples.md.
  --no-log    Disable command logging for this invocation.
'@ | Write-Host
}

function Show-WapExamples {
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $examplesPath = Join-Path $RepositoryRoot 'docs\examples.md'
    if (-not (Test-Path -LiteralPath $examplesPath -PathType Leaf)) {
        throw "Examples file not found at '$examplesPath'."
    }

    Get-Content -LiteralPath $examplesPath -Raw | Write-Host
}

function Test-WapCliMissingToken {
    param([AllowNull()][object[]] $Arguments)

    return (-not $Arguments -or
        -not $Arguments.Count -or
        [string]::IsNullOrWhiteSpace([string]$Arguments[0]))
}

function New-WapCliSuggestionMessage {
    param(
        [Parameter(Mandatory)][string] $Message,
        [Parameter(Mandatory)][string[]] $Completions
    )

    $lines = @($Message, '', 'Try one of:')
    $lines += $Completions | ForEach-Object { "  $_" }
    return ($lines -join [Environment]::NewLine)
}

function New-WapIncompleteCommandMessage {
    param(
        [Parameter(Mandatory)][string] $CommandLine,
        [Parameter(Mandatory)][string[]] $Completions
    )

    return New-WapCliSuggestionMessage -Message "Command is incomplete: $CommandLine" -Completions $Completions
}

function New-WapUnknownCommandMessage {
    param(
        [Parameter(Mandatory)][string] $CommandLine,
        [Parameter(Mandatory)][string] $UnknownToken,
        [Parameter(Mandatory)][string[]] $Completions
    )

    return New-WapCliSuggestionMessage -Message "Unknown command part '$UnknownToken' in: $CommandLine" -Completions $Completions
}

function Invoke-WapCli {
    [CmdletBinding()]
    param(
        [string] $Command,
        [string[]] $Arguments,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $argsList = if ($null -eq $Arguments) { @() } else { @($Arguments) }
    $whatIf = $argsList -contains '-WhatIf'
    $argsList = @($argsList | Where-Object { $_ -ne '-WhatIf' })
    $commandName = if ([string]::IsNullOrWhiteSpace($Command)) { 'help' } else { $Command }
    Assert-WapPowerShellVersion -CommandName $commandName

    switch ($Command) {
        'init' {
            $unknownInitArguments = @($argsList | Where-Object { -not [string]::IsNullOrEmpty($_) -and $_ -ne '--skip-prereqs' })
            if ($unknownInitArguments.Count -gt 0) {
                throw (New-WapUnknownCommandMessage -CommandLine '.\wap.ps1 init' -UnknownToken $unknownInitArguments[0] -Completions @(
                    '.\wap.ps1 init',
                    '.\wap.ps1 init --skip-prereqs'
                ))
            }
            Initialize-Wap -RepositoryRoot $RepositoryRoot -SkipPrereqs:($argsList -contains '--skip-prereqs') -WhatIf:$whatIf
            return
        }
        'config' {
            $configCompletions = @(
                '.\wap.ps1 config show',
                '.\wap.ps1 config set bootstrapConfigPath <path>',
                '.\wap.ps1 config set configPath <path>',
                '.\wap.ps1 config set workspaceRoot <path>',
                '.\wap.ps1 config set profilesRoot <path>',
                '.\wap.ps1 config set logging.enabled <true|false>',
                '.\wap.ps1 config set logging.retentionDays <days>',
                '.\wap.ps1 config set logging.root <path>',
                '.\wap.ps1 config set sandbox.installWinget <true|false>'
            )
            if (Test-WapCliMissingToken -Arguments $argsList) {
                throw (New-WapIncompleteCommandMessage -CommandLine '.\wap.ps1 config' -Completions $configCompletions)
            }
            switch ($argsList[0]) {
                'show' {
                    if ($argsList.Count -ne 1) { throw 'Usage: .\wap.ps1 config show' }
                    Show-WapConfig -RepositoryRoot $RepositoryRoot
                }
                'set' {
                    if ($argsList.Count -lt 3) {
                        throw (New-WapIncompleteCommandMessage -CommandLine '.\wap.ps1 config set' -Completions @(
                            '.\wap.ps1 config set bootstrapConfigPath <path>',
                            '.\wap.ps1 config set configPath <path>',
                            '.\wap.ps1 config set workspaceRoot <path>',
                            '.\wap.ps1 config set profilesRoot <path>',
                            '.\wap.ps1 config set logging.enabled <true|false>',
                            '.\wap.ps1 config set logging.retentionDays <days>',
                            '.\wap.ps1 config set logging.root <path>',
                            '.\wap.ps1 config set sandbox.installWinget <true|false>'
                        ))
                    }
                    $value = @($argsList[2..($argsList.Count - 1)]) -join ' '
                    Set-WapConfig -Key $argsList[1] -Value $value -RepositoryRoot $RepositoryRoot -WhatIf:$whatIf
                }
                default {
                    throw (New-WapUnknownCommandMessage -CommandLine '.\wap.ps1 config' -UnknownToken ([string]$argsList[0]) -Completions $configCompletions)
                }
            }
            return
        }
        'logs' {
            $logsCompletions = @('.\wap.ps1 logs cleanup [-WhatIf]')
            if (Test-WapCliMissingToken -Arguments $argsList) {
                throw (New-WapIncompleteCommandMessage -CommandLine '.\wap.ps1 logs' -Completions $logsCompletions)
            }
            switch ($argsList[0]) {
                'cleanup' {
                    if ($argsList.Count -ne 1) { throw 'Usage: .\wap.ps1 logs cleanup [-WhatIf]' }
                    Remove-WapLogs -RepositoryRoot $RepositoryRoot -WhatIf:$whatIf
                }
                default {
                    throw (New-WapUnknownCommandMessage -CommandLine '.\wap.ps1 logs' -UnknownToken ([string]$argsList[0]) -Completions $logsCompletions)
                }
            }
            return
        }
        'profile' {
            $profileCompletions = @(
                '.\wap.ps1 profile status',
                '.\wap.ps1 profile list',
                '.\wap.ps1 profile show <name>',
                '.\wap.ps1 profile new <name>',
                '.\wap.ps1 profile install <name> [--sandbox]',
                '.\wap.ps1 profile activate <name>',
                '.\wap.ps1 profile deactivate <name>',
                '.\wap.ps1 profile uninstall <name>',
                '.\wap.ps1 profile cleanup <name> [--user-data] [--registry] [--all]',
                '.\wap.ps1 profile delete <name>',
                '.\wap.ps1 profile winget <add|list|remove> ...',
                '.\wap.ps1 profile capture <add|list|enable|disable|remove|copy|edit|refresh|versions|select-version|merge> ...'
            )
            if (Test-WapCliMissingToken -Arguments $argsList) {
                throw (New-WapIncompleteCommandMessage -CommandLine '.\wap.ps1 profile' -Completions $profileCompletions)
            }
            $action = $argsList[0]
            if ($action -eq 'winget') {
                if ($argsList.Count -lt 3) {
                    throw (New-WapIncompleteCommandMessage -CommandLine '.\wap.ps1 profile winget' -Completions @(
                        '.\wap.ps1 profile winget add <profile> <packageId> [--source <source>]',
                        '.\wap.ps1 profile winget list <profile>',
                        '.\wap.ps1 profile winget enable <profile> <packageId> [--source <source>]',
                        '.\wap.ps1 profile winget disable <profile> <packageId> [--source <source>]',
                        '.\wap.ps1 profile winget remove <profile> <packageId> [--source <source>] [-WhatIf]'
                    ))
                }
                $wingetAction = $argsList[1]
                switch ($wingetAction) {
                    'add' {
                        if ($argsList.Count -lt 4) { throw 'Usage: .\wap.ps1 profile winget add <profile> <packageId> [--source <source>]' }
                        Add-WapProfileWingetPackage -ProfileName $argsList[2] `
                            -PackageId $argsList[3] `
                            -RepositoryRoot $RepositoryRoot `
                            -Source (Get-WapCliOption -Arguments $argsList -Name 'source')
                    }
                    'list' {
                        if ($argsList.Count -ne 3) { throw 'Usage: .\wap.ps1 profile winget list <profile>' }
                        Show-WapProfileWingetPackages -ProfileName $argsList[2] -RepositoryRoot $RepositoryRoot
                    }
                    'enable' {
                        if ($argsList.Count -lt 4) { throw 'Usage: .\wap.ps1 profile winget enable <profile> <packageId> [--source <source>]' }
                        Set-WapProfileWingetPackageEnabled -ProfileName $argsList[2] `
                            -PackageId $argsList[3] `
                            -RepositoryRoot $RepositoryRoot `
                            -Enabled $true `
                            -Source (Get-WapCliOption -Arguments $argsList -Name 'source')
                    }
                    'disable' {
                        if ($argsList.Count -lt 4) { throw 'Usage: .\wap.ps1 profile winget disable <profile> <packageId> [--source <source>]' }
                        Set-WapProfileWingetPackageEnabled -ProfileName $argsList[2] `
                            -PackageId $argsList[3] `
                            -RepositoryRoot $RepositoryRoot `
                            -Enabled $false `
                            -Source (Get-WapCliOption -Arguments $argsList -Name 'source')
                    }
                    'remove' {
                        if ($argsList.Count -lt 4) { throw 'Usage: .\wap.ps1 profile winget remove <profile> <packageId> [--source <source>] [-WhatIf]' }
                        Remove-WapProfileWingetPackage -ProfileName $argsList[2] `
                            -PackageId $argsList[3] `
                            -RepositoryRoot $RepositoryRoot `
                            -Source (Get-WapCliOption -Arguments $argsList -Name 'source') `
                            -WhatIf:$whatIf
                    }
                    default {
                        throw (New-WapUnknownCommandMessage -CommandLine '.\wap.ps1 profile winget' -UnknownToken ([string]$wingetAction) -Completions @(
                            '.\wap.ps1 profile winget add <profile> <packageId> [--source <source>]',
                            '.\wap.ps1 profile winget list <profile>',
                            '.\wap.ps1 profile winget enable <profile> <packageId> [--source <source>]',
                            '.\wap.ps1 profile winget disable <profile> <packageId> [--source <source>]',
                            '.\wap.ps1 profile winget remove <profile> <packageId> [--source <source>] [-WhatIf]'
                        ))
                    }
                }
                return
            }
            if ($action -eq 'capture') {
                if ($argsList.Count -lt 3) {
                    throw (New-WapIncompleteCommandMessage -CommandLine '.\wap.ps1 profile capture' -Completions @(
                        '.\wap.ps1 profile capture add <profile> <capture> [--id <id>] [--name <name>] [--description <text>]',
                        '.\wap.ps1 profile capture list <profile>',
                        '.\wap.ps1 profile capture enable <profile> <captureId>',
                        '.\wap.ps1 profile capture disable <profile> <captureId>',
                        '.\wap.ps1 profile capture remove <profile> <captureId> [-WhatIf]',
                        '.\wap.ps1 profile capture copy <fromProfile> <captureId> <toProfile> [--id <id>] [--name <name>] [--description <text>]',
                        '.\wap.ps1 profile capture edit <profile> <captureId> [--name <name>] [--description <text>]',
                        '.\wap.ps1 profile capture refresh <profile> <captureId> <capture> [--description <text>] [--apply]',
                        '.\wap.ps1 profile capture versions <profile> <captureId>',
                        '.\wap.ps1 profile capture select-version <profile> <captureId> <base|latest|version>',
                        '.\wap.ps1 profile capture merge <profile> <captureId> [--up-to <version>]'
                    ))
                }
                $captureAction = $argsList[1]
                switch ($captureAction) {
                    'add' {
                        if ($argsList.Count -lt 4) {
                            throw 'Usage: .\wap.ps1 profile capture add <profile> <capture> [--id <id>] [--name <name>] [--description <text>]'
                        }
                        Add-WapProfileCapture -ProfileName $argsList[2] `
                            -CaptureName $argsList[3] `
                            -RepositoryRoot $RepositoryRoot `
                            -CaptureId (Get-WapCliOption -Arguments $argsList -Name 'id') `
                            -DisplayName (Get-WapCliOption -Arguments $argsList -Name 'name') `
                            -Description (Get-WapCliOption -Arguments $argsList -Name 'description')
                    }
                    'list' {
                        if ($argsList.Count -ne 3) { throw 'Usage: .\wap.ps1 profile capture list <profile>' }
                        Show-WapProfileCaptures -ProfileName $argsList[2] -RepositoryRoot $RepositoryRoot
                    }
                    'enable' {
                        if ($argsList.Count -ne 4) { throw 'Usage: .\wap.ps1 profile capture enable <profile> <captureId>' }
                        Set-WapProfileCaptureEnabled -ProfileName $argsList[2] -CaptureId $argsList[3] -RepositoryRoot $RepositoryRoot -Enabled $true
                    }
                    'disable' {
                        if ($argsList.Count -ne 4) { throw 'Usage: .\wap.ps1 profile capture disable <profile> <captureId>' }
                        Set-WapProfileCaptureEnabled -ProfileName $argsList[2] -CaptureId $argsList[3] -RepositoryRoot $RepositoryRoot -Enabled $false
                    }
                    'remove' {
                        if ($argsList.Count -lt 4) { throw 'Usage: .\wap.ps1 profile capture remove <profile> <captureId> [-WhatIf]' }
                        Remove-WapProfileCapture -ProfileName $argsList[2] -CaptureId $argsList[3] -RepositoryRoot $RepositoryRoot -WhatIf:$whatIf
                    }
                    'copy' {
                        if ($argsList.Count -lt 5) {
                            throw 'Usage: .\wap.ps1 profile capture copy <fromProfile> <captureId> <toProfile> [--id <id>] [--name <name>] [--description <text>]'
                        }
                        Copy-WapProfileCapture -FromProfileName $argsList[2] `
                            -CaptureId $argsList[3] `
                            -ToProfileName $argsList[4] `
                            -RepositoryRoot $RepositoryRoot `
                            -NewCaptureId (Get-WapCliOption -Arguments $argsList -Name 'id') `
                            -DisplayName (Get-WapCliOption -Arguments $argsList -Name 'name') `
                            -Description (Get-WapCliOption -Arguments $argsList -Name 'description')
                    }
                    'edit' {
                        if ($argsList.Count -lt 4) {
                            throw 'Usage: .\wap.ps1 profile capture edit <profile> <captureId> [--name <name>] [--description <text>]'
                        }
                        Edit-WapProfileCapture -ProfileName $argsList[2] `
                            -CaptureId $argsList[3] `
                            -RepositoryRoot $RepositoryRoot `
                            -DisplayName (Get-WapCliOption -Arguments $argsList -Name 'name') `
                            -Description (Get-WapCliOption -Arguments $argsList -Name 'description')
                    }
                    'refresh' {
                        if ($argsList.Count -lt 5) {
                            throw 'Usage: .\wap.ps1 profile capture refresh <profile> <captureId> <capture> [--description <text>] [--apply]'
                        }
                        Refresh-WapProfileCapture -ProfileName $argsList[2] `
                            -CaptureId $argsList[3] `
                            -CaptureName $argsList[4] `
                            -RepositoryRoot $RepositoryRoot `
                            -Description (Get-WapCliOption -Arguments $argsList -Name 'description') `
                            -Apply:(Get-WapCliSwitch -Arguments $argsList -Name 'apply')
                    }
                    'versions' {
                        if ($argsList.Count -ne 4) { throw 'Usage: .\wap.ps1 profile capture versions <profile> <captureId>' }
                        Show-WapProfileCaptureVersions -ProfileName $argsList[2] -CaptureId $argsList[3] -RepositoryRoot $RepositoryRoot
                    }
                    'select-version' {
                        if ($argsList.Count -ne 5) { throw 'Usage: .\wap.ps1 profile capture select-version <profile> <captureId> <base|latest|version>' }
                        Select-WapProfileCaptureVersion -ProfileName $argsList[2] -CaptureId $argsList[3] -Version $argsList[4] -RepositoryRoot $RepositoryRoot
                    }
                    'merge' {
                        if ($argsList.Count -lt 4) { throw 'Usage: .\wap.ps1 profile capture merge <profile> <captureId> [--up-to <version>]' }
                        Merge-WapProfileCaptureVersions -ProfileName $argsList[2] `
                            -CaptureId $argsList[3] `
                            -RepositoryRoot $RepositoryRoot `
                            -UpToVersion (Get-WapCliOption -Arguments $argsList -Name 'up-to')
                    }
                    default {
                        throw (New-WapUnknownCommandMessage -CommandLine '.\wap.ps1 profile capture' -UnknownToken ([string]$captureAction) -Completions @(
                            '.\wap.ps1 profile capture add <profile> <capture> [--id <id>] [--name <name>] [--description <text>]',
                            '.\wap.ps1 profile capture list <profile>',
                            '.\wap.ps1 profile capture enable <profile> <captureId>',
                            '.\wap.ps1 profile capture disable <profile> <captureId>',
                            '.\wap.ps1 profile capture remove <profile> <captureId> [-WhatIf]',
                            '.\wap.ps1 profile capture copy <fromProfile> <captureId> <toProfile> [--id <id>] [--name <name>] [--description <text>]',
                            '.\wap.ps1 profile capture edit <profile> <captureId> [--name <name>] [--description <text>]',
                            '.\wap.ps1 profile capture refresh <profile> <captureId> <capture> [--description <text>] [--apply]',
                            '.\wap.ps1 profile capture versions <profile> <captureId>',
                            '.\wap.ps1 profile capture select-version <profile> <captureId> <base|latest|version>',
                            '.\wap.ps1 profile capture merge <profile> <captureId> [--up-to <version>]'
                        ))
                    }
                }
                return
            }
            if ($action -in @('status', 'list')) { Show-WapStatus $RepositoryRoot; return }
            if ($argsList.Count -lt 2) {
                throw (New-WapIncompleteCommandMessage -CommandLine ".\wap.ps1 profile $action" -Completions @(".\wap.ps1 profile $action <name>"))
            }
            $name = $argsList[1]
            switch ($action) {
                'install' {
                    if (Get-WapCliSwitch -Arguments $argsList -Name 'sandbox') {
                        Start-WapProfileSandboxInstall -Name $name -RepositoryRoot $RepositoryRoot -WhatIf:$whatIf
                    }
                    else {
                        Install-WapProfile $name $RepositoryRoot -WhatIf:$whatIf
                    }
                }
                'uninstall' {
                    Uninstall-WapProfile $name $RepositoryRoot `
                        -RemoveUserData:(Get-WapCliSwitch -Arguments $argsList -Name 'remove-user-data') `
                        -RemoveRegistry:(Get-WapCliSwitch -Arguments $argsList -Name 'remove-registry') `
                        -WhatIf:$whatIf
                }
                'cleanup' {
                    $all = Get-WapCliSwitch -Arguments $argsList -Name 'all'
                    Invoke-WapProfileCleanup -Name $name `
                        -RepositoryRoot $RepositoryRoot `
                        -RemoveUserData:($all -or (Get-WapCliSwitch -Arguments $argsList -Name 'user-data')) `
                        -RemoveRegistry:($all -or (Get-WapCliSwitch -Arguments $argsList -Name 'registry')) `
                        -WhatIf:$whatIf
                }
                'new' { New-WapProfileDefinition $name $RepositoryRoot -WhatIf:$whatIf }
                'show' { Show-WapProfile -ProfileName $name -RepositoryRoot $RepositoryRoot }
                'activate' { Enable-WapProfile $name $RepositoryRoot -WhatIf:$whatIf }
                'deactivate' { Disable-WapProfile $name $RepositoryRoot -WhatIf:$whatIf }
                'delete' { Remove-WapProfileDefinition $name $RepositoryRoot -WhatIf:$whatIf }
                default {
                    throw (New-WapUnknownCommandMessage -CommandLine '.\wap.ps1 profile' -UnknownToken ([string]$action) -Completions $profileCompletions)
                }
            }
            return
        }
        'capture' {
            $captureCompletions = @(
                '.\wap.ps1 capture list',
                '.\wap.ps1 capture new <name>',
                '.\wap.ps1 capture start <name> [--no-winget]',
                '.\wap.ps1 capture rename <name> <newName>',
                '.\wap.ps1 capture validate <name>',
                '.\wap.ps1 capture diff <name>',
                '.\wap.ps1 capture applyfilter <name>',
                '.\wap.ps1 capture remove <name> [-WhatIf]'
            )
            if (Test-WapCliMissingToken -Arguments $argsList) {
                throw (New-WapIncompleteCommandMessage -CommandLine '.\wap.ps1 capture' -Completions $captureCompletions)
            }
            $captureAction = $argsList[0]
            switch ($captureAction) {
                'list' {
                    if ($argsList.Count -ne 1) { throw 'Usage: .\wap.ps1 capture list' }
                    Show-WapCaptureSessions -RepositoryRoot $RepositoryRoot
                }
                'rename' {
                    if ($argsList.Count -ne 3) { throw 'Usage: .\wap.ps1 capture rename <name> <newName> [-WhatIf]' }
                    Rename-WapCaptureSession -Name $argsList[1] -NewName $argsList[2] -RepositoryRoot $RepositoryRoot -WhatIf:$whatIf
                }
                'new' {
                    if ($argsList.Count -ne 2) { throw 'Usage: .\wap.ps1 capture new <name>' }
                    New-WapCapture $argsList[1] $RepositoryRoot
                }
                'start' {
                    $noWinget = $argsList -contains '--no-winget'
                    $captureStartArgs = @($argsList | Where-Object { $_ -ne '--no-winget' })
                    if ($captureStartArgs.Count -ne 2) { throw 'Usage: .\wap.ps1 capture start <name> [--no-winget] [-WhatIf]' }
                    Start-WapInteractiveCapture $captureStartArgs[1] $RepositoryRoot -NoWinget:$noWinget -WhatIf:$whatIf
                }
                'validate' {
                    if ($argsList.Count -ne 2) { throw 'Usage: .\wap.ps1 capture validate <name>' }
                    Test-WapInteractiveCapture $argsList[1] $RepositoryRoot
                }
                'diff' {
                    if ($argsList.Count -ne 2) { throw 'Usage: .\wap.ps1 capture diff <name>' }
                    Show-WapCaptureDiff $argsList[1] $RepositoryRoot
                }
                'applyfilter' {
                    if ($argsList.Count -ne 2) { throw 'Usage: .\wap.ps1 capture applyfilter <name>' }
                    Invoke-WapCaptureFilterApplication $argsList[1] $RepositoryRoot
                }
                'remove' {
                    if ($argsList.Count -ne 2) { throw 'Usage: .\wap.ps1 capture remove <name> [-WhatIf]' }
                    Remove-WapCaptureSession $argsList[1] $RepositoryRoot -WhatIf:$whatIf
                }
                default {
                    throw (New-WapUnknownCommandMessage -CommandLine '.\wap.ps1 capture' -UnknownToken ([string]$captureAction) -Completions $captureCompletions)
                }
            }
            return
        }
        { $_ -in @('', 'help', '--help', '-h') } { Show-WapHelp; return }
        { $_ -in @('examples', '--examples') } { Show-WapExamples -RepositoryRoot $RepositoryRoot; return }
        default { Show-WapHelp; throw "Unknown command '$Command'." }
    }
}

Export-ModuleMember -Function @(
    'ConvertFrom-WapSimpleYaml',
    'Get-WapConfig',
    'Show-WapConfig',
    'Set-WapConfig',
    'Start-WapCommandLog',
    'Stop-WapCommandLog',
    'Invoke-WapLogRetentionCleanup',
    'Remove-WapLogs',
    'Import-WapProfile',
    'Get-WapState',
    'Install-WapProfile',
    'Start-WapProfileSandboxInstall',
    'Enable-WapProfile',
    'Disable-WapProfile',
    'Uninstall-WapProfile',
    'Show-WapProfile',
    'Add-WapProfileWingetPackage',
    'Set-WapProfileWingetPackageEnabled',
    'Show-WapProfileWingetPackages',
    'Remove-WapProfileWingetPackage',
    'Set-WapProfileCaptureEnabled',
    'Remove-WapProfileDefinition',
    'Remove-WapCaptureSession',
    'Rename-WapCaptureSession',
    'Show-WapCaptureSessions',
    'Save-WapSandboxWingetPrerequisites',
    'Start-WapInteractiveCapture',
    'Test-WapInteractiveCapture',
    'Show-WapCaptureDiff',
    'Invoke-WapCaptureFilterApplication',
    'New-WapCapture',
    'Initialize-Wap',
    'Install-WapPrerequisites',
    'Install-WapWingetPrerequisite',
    'Invoke-WapCli'
)
