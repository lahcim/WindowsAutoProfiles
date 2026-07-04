#requires -Version 5.1
# Author: Michal Zygmunt <lahcim@fajne.com>

Set-StrictMode -Version Latest

$script:WapMinimumPowerShellVersion = [version]'5.1'
$script:WapVersion = '1.1'
$script:WapLastUpdated = '2026-07-04T02:24:12Z'

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

function Get-WapRawConfig {
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $path = Join-Path $RepositoryRoot 'wap.config.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            version = 1
            workspaceRoot = '%USERPROFILE%\Workspaces'
            logging = [pscustomobject]@{
                enabled = $true
                retentionDays = 30
            }
        }
    }

    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
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

    [pscustomobject]@{
        enabled = $enabled
        retentionDays = $retentionDays
        root = Join-Path $RepositoryRoot '.logs'
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
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $config = Get-WapLogConfig -RepositoryRoot $RepositoryRoot
    if ($config.retentionDays -eq 0) { return }
    if (-not (Test-Path -LiteralPath $config.root -PathType Container)) { return }
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * $config.retentionDays)
    Get-ChildItem -LiteralPath $config.root -Filter '*.log' -File -ErrorAction SilentlyContinue |
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

    $path = Join-Path $RepositoryRoot 'wap.config.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Configuration was not found at '$path'. Run '.\wap.ps1 init'."
    }

    $config = Get-WapRawConfig -RepositoryRoot $RepositoryRoot

    if (-not $config.PSObject.Properties['version'] -or $config.version -ne 1) {
        throw "Unsupported or missing configuration version. Expected version 1."
    }
    if (-not $config.PSObject.Properties['workspaceRoot'] -or
        [string]::IsNullOrWhiteSpace([string]$config.workspaceRoot)) {
        throw "Configuration file '$path' must define workspaceRoot."
    }

    $workspaceRoot = [Environment]::ExpandEnvironmentVariables([string]$config.workspaceRoot)
    if (-not [IO.Path]::IsPathRooted($workspaceRoot)) {
        throw "workspaceRoot must resolve to an absolute path. Resolved value: '$workspaceRoot'."
    }

    $logConfig = Get-WapLogConfig -RepositoryRoot $RepositoryRoot
    [pscustomobject]@{
        version = 1
        workspaceRoot = $workspaceRoot.TrimEnd([char[]]@('\', '/'))
        loggingEnabled = $logConfig.enabled
        loggingRetentionDays = $logConfig.retentionDays
        logRoot = $logConfig.root
        source = $path
    }
}
function Show-WapConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
    $raw = Get-Content -LiteralPath $config.source -Raw | ConvertFrom-Json
    [pscustomobject]@{
        Version = $config.version
        WorkspaceRoot = [string]$raw.workspaceRoot
        ResolvedWorkspaceRoot = $config.workspaceRoot
        LoggingEnabled = $config.loggingEnabled
        LoggingRetentionDays = $config.loggingRetentionDays
        LogRoot = $config.logRoot
        ConfigPath = $config.source
    } | Format-List
}

function Set-WapConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $path = Join-Path $RepositoryRoot 'wap.config.json'
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

    switch ($Key) {
        'workspaceRoot' {
            if ([string]::IsNullOrWhiteSpace($Value)) {
                throw 'workspaceRoot cannot be empty.'
            }
            $resolvedValue = [Environment]::ExpandEnvironmentVariables($storedValue)
            if (-not [IO.Path]::IsPathRooted($resolvedValue)) {
                throw "workspaceRoot must resolve to an absolute path. Resolved value: '$resolvedValue'."
            }
            $raw.workspaceRoot = $storedValue
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
        default {
            throw "Unknown configuration key '$Key'. Supported keys: workspaceRoot, logging.enabled, logging.retentionDays."
        }
    }

    if ($PSCmdlet.ShouldProcess($path, "Set $Key to '$storedValue'")) {
        $temp = "$path.tmp"
        $raw | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $path -Force
    }

    if (-not $WhatIfPreference) {
        Write-Host "$Key set to '$storedValue'."
        if ($resolvedValue) { Write-Host "Resolved workspace root: $resolvedValue" }
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

    $path = Join-Path $RepositoryRoot "profiles/$Name/profile.yaml"
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

    $config = Get-WapConfig -RepositoryRoot $RepositoryRoot
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
                $packages += [pscustomobject]@{ id = $app; source = 'winget' }
            }
            else {
                $id = if ($app -is [System.Collections.IDictionary]) { $app['id'] } else { $app.id }
                $source = if ($app -is [System.Collections.IDictionary]) { $app['source'] } else { $app.source }
                if (-not $id) { throw "Every app in '$Name' must have an id." }
                $packages += [pscustomobject]@{
                    id = [string]$id
                    source = if ($source) { [string]$source } else { 'winget' }
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
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
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

    Write-Host "  Packages: $($profile.apps.Count) declared"
    foreach ($app in $profile.apps) {
        if ($app.source -ne 'winget') { throw "Unsupported package source '$($app.source)' for '$($app.id)'." }
        Write-Host "    [check] $($app.id)"
        if ($PSCmdlet.ShouldProcess($app.id, 'Install winget package')) {
            $winget = Get-Command winget -ErrorAction SilentlyContinue
            if (-not $winget) { throw 'winget was not found. Install App Installer or rerun with -WhatIf.' }
            & $winget.Source list --id $app.id --exact --accept-source-agreements | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    [ready] $($app.id) is already installed"
                continue
            }
            & $winget.Source install --id $app.id --exact --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { throw "winget failed to install '$($app.id)' (exit $LASTEXITCODE)." }
            $installedPackages += $app.id
            Write-Host "    [installed] $($app.id)"
        }
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
            packages = @($profile.apps.id)
            installedPackages = @($installedPackages)
            shortcuts = @($createdShortcuts)
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

    $capturesRoot = Join-Path $RepositoryRoot "profiles/$Name/captures"
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
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $keys = [System.Collections.ArrayList]::new()
    foreach ($entry in (Get-WapProfileCaptureManifests -Name $Name -RepositoryRoot $RepositoryRoot)) {
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
        $registryKeys = @(Get-WapProfileRegistryCleanupKeys -Name $Name -RepositoryRoot $RepositoryRoot)
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
    Write-Host "  Packages: $($ownedPackages.Count) installed by this profile"
    foreach ($package in $ownedPackages) {
        if ($package -in $packagesUsedElsewhere) {
            Write-Host "    [keep] $package is declared by another profile"
            continue
        }
        Write-Host "    [remove] $package"
        if ($PSCmdlet.ShouldProcess($package, 'Uninstall winget package')) {
            $winget = Get-Command winget -ErrorAction SilentlyContinue
            if (-not $winget) { throw 'winget was not found. Rerun with -WhatIf to preview.' }
            & $winget.Source uninstall --id $package --exact
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
        $registryKeys = @(Get-WapProfileRegistryCleanupKeys -Name $Name -RepositoryRoot $RepositoryRoot)
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
    $profilesPath = Join-Path $RepositoryRoot 'profiles'
    $availableNames = @(
        Get-ChildItem -LiteralPath $profilesPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'profile.yaml') } |
            ForEach-Object Name
    )
    $names = @($availableNames + @($state.profiles.Keys) | Sort-Object -Unique)
    $installedCount = @($state.profiles.Keys).Count
    $activeName = if ($state.activeProfile) { [string]$state.activeProfile } else { '<none>' }

    Write-Host "Workspace root:  $($config.workspaceRoot)"
    Write-Host "Active profile: $activeName"
    Write-Host "Installed:      $installedCount"
    if (-not $names.Count) {
        Write-Host 'No profiles are available or installed.'
        return
    }

    $rows = foreach ($name in $names) {
        $isInstalled = $state.profiles.Contains($name) -and [bool]$state.profiles[$name].installed
        $isActive = $isInstalled -and $state.activeProfile -eq $name
        [pscustomobject]@{
            Name = $name
            Installed = $isInstalled
            Status = if ($isActive) { 'Active' } elseif ($isInstalled) { 'Inactive' } else { 'Not installed' }
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
    $started = Get-Date
    $lastReport = -15
    Write-Host "Waiting for Sandbox baseline to finish (timeout: $TimeoutSeconds seconds)..."
    try {
        while ($true) {
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
                Write-Host "  Still capturing baseline... $elapsed seconds elapsed"
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
function Start-WapInteractiveCapture {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [int] $BaselineTimeoutSeconds = 900
    )

    $captureRoot = Get-WapCaptureSessionPath -Name $Name -RepositoryRoot $RepositoryRoot
    if (Test-Path -LiteralPath $captureRoot) {
        throw "Capture session '$Name' already exists at '$captureRoot'. No files were overwritten."
    }

    $templateRoot = Join-Path $RepositoryRoot 'templates/capture'
    $requiredTemplates = @(
        'Capture-Common.ps1',
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
    if ($PSCmdlet.ShouldProcess($captureRoot, 'Create capture session and launch Windows Sandbox')) {
        foreach ($directory in @('baseline', 'after', 'output')) {
            New-Item -ItemType Directory -Path (Join-Path $captureRoot $directory) -Force | Out-Null
            Write-Host "  [created] $directory/"
        }
        foreach ($scriptName in @('Capture-Common.ps1', 'Capture-Baseline.ps1', 'Capture-Finalize.ps1', 'capture-filters.json')) {
            Copy-Item -LiteralPath (Join-Path $templateRoot $scriptName) -Destination (Join-Path $captureRoot $scriptName)
            Write-Host "  [generated] $scriptName"
        }

        [ordered]@{
            version = 1
            profileName = $Name
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
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
        Write-Host 'Inside Sandbox, finalize with:'
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
    $profilePath = Join-Path $RepositoryRoot "profiles/$ProfileName/profile.yaml"
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw "Profile '$ProfileName' was not found at '$profilePath'."
    }
    return Join-Path $RepositoryRoot "profiles/$ProfileName/captures"
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
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $targetRoot 'metadata.json') -Encoding UTF8

    Write-Host "Added capture '$id' to profile '$ProfileName'."
}

function Show-WapProfileCaptures {
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $root = Get-WapProfileCaptureRoot -ProfileName $ProfileName -RepositoryRoot $RepositoryRoot
    $items = @(
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'metadata.json') } |
            ForEach-Object { Get-Content -LiteralPath (Join-Path $_.FullName 'metadata.json') -Raw | ConvertFrom-Json }
    )
    if (-not $items.Count) {
        Write-Host "Profile '$ProfileName' has no captures."
        return
    }
    $items | Sort-Object id | Select-Object id, name, createdAt, addedAt, description | Format-Table -AutoSize -Wrap
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

function Show-WapCaptureDiff {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $manifest = Read-WapCaptureManifest -Name $Name -RepositoryRoot $RepositoryRoot
    $addedFiles = @($manifest.addedFiles | Where-Object { $null -ne $_ })
    $hasFilteredFiles = $null -ne $manifest.PSObject.Properties['filteredAddedFiles']
    $filteredFiles = if ($hasFilteredFiles) {
        @($manifest.filteredAddedFiles | Where-Object { $null -ne $_ })
    }
    else { @() }
    $changedRegistry = @($manifest.changedRegistryKeys | Where-Object { $null -ne $_ })
    $hasFilteredRegistry = $null -ne $manifest.PSObject.Properties['filteredRegistryKeys']
    $filteredRegistry = if ($hasFilteredRegistry) {
        @($manifest.filteredRegistryKeys | Where-Object { $null -ne $_ })
    }
    else { @() }
    $newServices = @($manifest.newServices | Where-Object { $null -ne $_ })
    $newShortcuts = @($manifest.newShortcuts | Where-Object { $null -ne $_ })
    $uninstallCommands = @($manifest.suspectedUninstallCommands | Where-Object { $null -ne $_ })
    $hasFilteredUninstallCommands = $null -ne $manifest.PSObject.Properties['filteredUninstallCommands']
    $filteredUninstallCommands = if ($hasFilteredUninstallCommands) {
        @($manifest.filteredUninstallCommands | Where-Object { $null -ne $_ })
    }
    else { @() }

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

    $profilesRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'profiles'))
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
function New-WapCapture {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid profile name '$Name'." }
    $directory = Join-Path $RepositoryRoot "profiles/$Name"
    $path = Join-Path $directory 'profile.yaml'
    if (Test-Path -LiteralPath $path) { throw "Profile '$Name' already exists." }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $packages = @()
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        $exportPath = Join-Path ([IO.Path]::GetTempPath()) "wap-export-$([guid]::NewGuid()).json"
        try {
            & $winget.Source export --output $exportPath --accept-source-agreements 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $exportPath)) {
                try {
                    $export = Get-Content -LiteralPath $exportPath -Raw | ConvertFrom-Json
                    $packages = @($export.Sources.Packages.PackageIdentifier | Sort-Object -Unique)
                } catch {
                    Write-Warning 'winget export could not be parsed; creating an empty apps list.'
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $exportPath) {
                Remove-Item -LiteralPath $exportPath -Force
            }
        }
    }

    $lines = @(
        "# Captured $(Get-Date -Format o)"
        "name: $Name"
        'apps:'
    )
    if ($packages.Count) {
        $lines += $packages | ForEach-Object { "  - id: $_" }
    }
    else { $lines += '  # - id: Git.Git' }
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
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    foreach ($directory in @('profiles', 'docs')) {
        New-Item -ItemType Directory -Path (Join-Path $RepositoryRoot $directory) -Force | Out-Null
    }
    $configPath = Join-Path $RepositoryRoot 'wap.config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        [ordered]@{
            version = 1
            workspaceRoot = '%USERPROFILE%\Workspaces'
            logging = [ordered]@{
                enabled = $true
                retentionDays = 30
            }
        } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
    }

    $statePath = Join-Path $RepositoryRoot '.wap-state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        Save-WapState (New-WapState) $RepositoryRoot
    }
    Write-Host "WindowsAutoProfiles initialized at '$RepositoryRoot'."
}

function Show-WapHelp {
    @'
WindowsAutoProfiles
Version: 1.1
Last updated: 2026-07-04T02:24:12Z
Author: Michal Zygmunt <lahcim@fajne.com>
Minimum PowerShell: 5.1

Usage:
  .\wap.ps1 init
  .\wap.ps1 config show
  .\wap.ps1 config set workspaceRoot <path> [-WhatIf]
  .\wap.ps1 config set logging.enabled <true|false> [-WhatIf]
  .\wap.ps1 config set logging.retentionDays <days> [-WhatIf]
  .\wap.ps1 logs cleanup [-WhatIf]
  .\wap.ps1 profile install <name> [-WhatIf]
  .\wap.ps1 profile uninstall <name> [--remove-user-data] [--remove-registry] [-WhatIf]
  .\wap.ps1 profile cleanup <name> [--user-data] [--registry] [--all] [-WhatIf]
  .\wap.ps1 profile activate <name> [-WhatIf]
  .\wap.ps1 profile deactivate <name> [-WhatIf]
  .\wap.ps1 profile delete <name> [-WhatIf]
  .\wap.ps1 profile status
  .\wap.ps1 profile list
  .\wap.ps1 profile capture add <profile> <capture> [--id <id>] [--name <name>] [--description <text>]
  .\wap.ps1 profile capture list <profile>
  .\wap.ps1 profile capture remove <profile> <captureId> [-WhatIf]
  .\wap.ps1 profile capture copy <fromProfile> <captureId> <toProfile> [--id <id>] [--name <name>] [--description <text>]
  .\wap.ps1 profile capture edit <profile> <captureId> [--name <name>] [--description <text>]
  .\wap.ps1 capture new <name>
  .\wap.ps1 capture start <name> [-WhatIf]
  .\wap.ps1 capture list
  .\wap.ps1 capture rename <name> <newName> [-WhatIf]
  .\wap.ps1 capture validate <name>
  .\wap.ps1 capture diff <name>
  .\wap.ps1 capture applyfilter <name>
  .\wap.ps1 capture remove <name> [-WhatIf]

Global options:
  --no-log    Disable command logging for this invocation.
'@ | Write-Host
}

function Invoke-WapCli {
    [CmdletBinding()]
    param(
        [string] $Command,
        [string[]] $Arguments,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $argsList = @($Arguments)
    $whatIf = $argsList -contains '-WhatIf'
    $argsList = @($argsList | Where-Object { $_ -ne '-WhatIf' })
    $commandName = if ([string]::IsNullOrWhiteSpace($Command)) { 'help' } else { $Command }
    Assert-WapPowerShellVersion -CommandName $commandName

    switch ($Command) {
        'init' { Initialize-Wap $RepositoryRoot; return }
        'config' {
            if (-not $argsList.Count) { throw 'Usage: .\wap.ps1 config show | config set <key> <value>' }
            switch ($argsList[0]) {
                'show' {
                    if ($argsList.Count -ne 1) { throw 'Usage: .\wap.ps1 config show' }
                    Show-WapConfig -RepositoryRoot $RepositoryRoot
                }
                'set' {
                    if ($argsList.Count -lt 3) {
                        throw 'Usage: .\wap.ps1 config set <workspaceRoot|logging.enabled|logging.retentionDays> <value>'
                    }
                    $value = @($argsList[2..($argsList.Count - 1)]) -join ' '
                    Set-WapConfig -Key $argsList[1] -Value $value -RepositoryRoot $RepositoryRoot -WhatIf:$whatIf
                }
                default { throw "Unknown config command '$($argsList[0])'." }
            }
            return
        }
        'logs' {
            if (-not $argsList.Count) { throw 'Usage: .\wap.ps1 logs cleanup [-WhatIf]' }
            switch ($argsList[0]) {
                'cleanup' {
                    if ($argsList.Count -ne 1) { throw 'Usage: .\wap.ps1 logs cleanup [-WhatIf]' }
                    Remove-WapLogs -RepositoryRoot $RepositoryRoot -WhatIf:$whatIf
                }
                default { throw "Unknown logs command '$($argsList[0])'." }
            }
            return
        }
        'profile' {
            if (-not $argsList.Count) { Show-WapHelp; throw 'Missing profile command.' }
            $action = $argsList[0]
            if ($action -eq 'capture') {
                if ($argsList.Count -lt 3) {
                    throw 'Usage: .\wap.ps1 profile capture <add|list|remove|copy|edit> ...'
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
                    default { throw "Unknown profile capture command '$captureAction'." }
                }
                return
            }
            if ($action -in @('status', 'list')) { Show-WapStatus $RepositoryRoot; return }
            if ($argsList.Count -lt 2) { throw "Missing profile name for '$action'." }
            $name = $argsList[1]
            switch ($action) {
                'install' { Install-WapProfile $name $RepositoryRoot -WhatIf:$whatIf }
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
                'activate' { Enable-WapProfile $name $RepositoryRoot -WhatIf:$whatIf }
                'deactivate' { Disable-WapProfile $name $RepositoryRoot -WhatIf:$whatIf }
                'delete' { Remove-WapProfileDefinition $name $RepositoryRoot -WhatIf:$whatIf }
                default { throw "Unknown profile command '$action'." }
            }
            return
        }
        'capture' {
            if (-not $argsList.Count) {
                throw 'Usage: .\wap.ps1 capture <list|new|start|rename|validate|diff|applyfilter|remove> ...'
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
                    if ($argsList.Count -ne 2) { throw 'Usage: .\wap.ps1 capture start <name> [-WhatIf]' }
                    Start-WapInteractiveCapture $argsList[1] $RepositoryRoot -WhatIf:$whatIf
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
                default { throw "Unknown capture command '$captureAction'." }
            }
            return
        }
        { $_ -in @('', 'help', '--help', '-h') } { Show-WapHelp; return }
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
    'Enable-WapProfile',
    'Disable-WapProfile',
    'Uninstall-WapProfile',
    'Remove-WapProfileDefinition',
    'Remove-WapCaptureSession',
    'Rename-WapCaptureSession',
    'Show-WapCaptureSessions',
    'Start-WapInteractiveCapture',
    'Test-WapInteractiveCapture',
    'Show-WapCaptureDiff',
    'Invoke-WapCaptureFilterApplication',
    'New-WapCapture',
    'Initialize-Wap',
    'Invoke-WapCli'
)
