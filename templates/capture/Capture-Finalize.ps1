#requires -Version 5.1
# Author: Michal Zygmunt <lahcim@fajne.com>

$ErrorActionPreference = 'Stop'
. 'C:\WAPCapture\Capture-Common.ps1'
Assert-CapturePowerShellVersion -CommandName 'capture finalize'
Assert-CaptureAdministrator -CommandName 'capture finalize' -ScriptPath $PSCommandPath

$baseline = Join-Path $script:CaptureRoot 'baseline'
$after = Join-Path $script:CaptureRoot 'after'
$output = Join-Path $script:CaptureRoot 'output'
$manifestPath = Join-Path $output 'capture-manifest.json'

$statusPath = Join-Path $baseline 'baseline-status.json'
if (-not (Test-Path -LiteralPath $statusPath)) {
    throw 'Baseline is incomplete: baseline-status.json is missing. Check C:\WAPCapture\output\baseline.log and start a new capture session.'
}
$baselineStatus = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
if (-not $baselineStatus.success -or -not (Test-Path -LiteralPath (Join-Path $baseline 'snapshot.json'))) {
    throw "Baseline failed or is incomplete: $($baselineStatus.error). Check C:\WAPCapture\output\baseline-error.txt and start a new capture session."
}

Write-Host 'WindowsAutoProfiles capture: recording after-state.'
try {
    Write-Progress -Id 10 -Activity 'WindowsAutoProfiles capture finalize' -Status 'Recording after-state' -PercentComplete 0
    Write-CaptureSnapshot -Destination $after
    New-Item -ItemType Directory -Path $output -Force | Out-Null

    Write-Progress -Id 10 -Activity 'WindowsAutoProfiles capture finalize' -Status 'Loading snapshots' -PercentComplete 20
    $baselineSnapshot = Get-Content -LiteralPath (Join-Path $baseline 'snapshot.json') -Raw | ConvertFrom-Json
    $afterSnapshot = Get-Content -LiteralPath (Join-Path $after 'snapshot.json') -Raw | ConvertFrom-Json

    $beforeFiles = @(Read-CaptureJsonItems -Path (Join-Path $baseline 'files.json'))
    $afterFiles = @(Read-CaptureJsonItems -Path (Join-Path $after 'files.json'))
}
finally {
    Write-Progress -Id 10 -Activity 'WindowsAutoProfiles capture finalize' -Completed
}

Write-Progress -Id 11 -Activity 'Computing capture diff' -Status 'Comparing filesystem' -PercentComplete 0
$beforeFileIndex = @{}
foreach ($item in $beforeFiles) {
    $beforeFileIndex[([string]$item.path).ToLowerInvariant()] = $item
}

$addedFiles = [System.Collections.ArrayList]::new()
$addedDirectories = [System.Collections.ArrayList]::new()
$changedFiles = [System.Collections.ArrayList]::new()
$filteredAddedFiles = [System.Collections.ArrayList]::new()
$seenAfterPaths = @{}
foreach ($item in $afterFiles) {
    $key = ([string]$item.path).ToLowerInvariant()
    if ($seenAfterPaths.ContainsKey($key)) { continue }
    $seenAfterPaths[$key] = $true
    if (-not $beforeFileIndex.ContainsKey($key)) {
        $noiseReason = Get-CaptureFileNoiseReason -FileChange $item
        if ($noiseReason) {
            Add-Member -InputObject $item -MemberType NoteProperty -Name reason -Value $noiseReason
            [void]$filteredAddedFiles.Add($item)
        }
        elseif ($item.itemType -eq 'File') { [void]$addedFiles.Add($item) }
        else { [void]$addedDirectories.Add($item) }
        continue
    }
    $previous = $beforeFileIndex[$key]
    if ($item.itemType -eq 'File' -and
        ($item.length -ne $previous.length -or $item.lastWriteUtc -ne $previous.lastWriteUtc)) {
        [void]$changedFiles.Add($item)
    }
}

Write-Progress -Id 11 -Activity 'Computing capture diff' -Status 'Comparing registry' -PercentComplete 30
$beforeRegistry = @{}
$afterRegistry = @{}
foreach ($definition in @(
    @{ file = 'HKCU-Software.reg'; hive = 'HKCU' },
    @{ file = 'HKLM-Software.reg'; hive = 'HKLM' }
)) {
    $beforeMap = Get-RegistryBlocks -Path (Join-Path $baseline $definition.file) `
        -Hive $definition.hive `
        -ProgressId 12 `
        -ParentProgressId 11 `
        -Activity "Parsing baseline registry $($definition.hive)"
    $afterMap = Get-RegistryBlocks -Path (Join-Path $after $definition.file) `
        -Hive $definition.hive `
        -ProgressId 12 `
        -ParentProgressId 11 `
        -Activity "Parsing after-state registry $($definition.hive)"
    foreach ($key in $beforeMap.Keys) { $beforeRegistry[$key] = $beforeMap[$key] }
    foreach ($key in $afterMap.Keys) { $afterRegistry[$key] = $afterMap[$key] }
}

$changedRegistryKeys = [System.Collections.ArrayList]::new()
$filteredRegistryKeys = [System.Collections.ArrayList]::new()
foreach ($key in $afterRegistry.Keys) {
    $change = $null
    if (-not $beforeRegistry.ContainsKey($key)) { $change = 'Added' }
    elseif ($beforeRegistry[$key].hash -ne $afterRegistry[$key].hash) { $change = 'Changed' }
    if ($change) {
        $entry = [pscustomobject]@{
            hive = $afterRegistry[$key].hive
            key = $afterRegistry[$key].key
            change = $change
        }
        $noiseReason = Get-CaptureRegistryNoiseReason -RegistryChange $entry
        if ($noiseReason) {
            Add-Member -InputObject $entry -MemberType NoteProperty -Name reason -Value $noiseReason
            [void]$filteredRegistryKeys.Add($entry)
        }
        else {
            [void]$changedRegistryKeys.Add($entry)
        }
    }
}
foreach ($key in $beforeRegistry.Keys) {
    if (-not $afterRegistry.ContainsKey($key)) {
        $entry = [pscustomobject]@{
            hive = $beforeRegistry[$key].hive
            key = $beforeRegistry[$key].key
            change = 'Removed'
        }
        $noiseReason = Get-CaptureRegistryNoiseReason -RegistryChange $entry
        if ($noiseReason) {
            Add-Member -InputObject $entry -MemberType NoteProperty -Name reason -Value $noiseReason
            [void]$filteredRegistryKeys.Add($entry)
        }
        else {
            [void]$changedRegistryKeys.Add($entry)
        }
    }
}

Write-Progress -Id 11 -Activity 'Computing capture diff' -Status 'Comparing services' -PercentComplete 60
$beforeServices = @(Read-CaptureJsonItems -Path (Join-Path $baseline 'services.json'))
$afterServices = @(Read-CaptureJsonItems -Path (Join-Path $after 'services.json'))
$beforeServiceNames = @{}
foreach ($service in $beforeServices) { $beforeServiceNames[$service.Name.ToLowerInvariant()] = $true }
$newServices = @($afterServices | Where-Object {
    -not $beforeServiceNames.ContainsKey($_.Name.ToLowerInvariant())
})

Write-Progress -Id 11 -Activity 'Computing capture diff' -Status 'Comparing scheduled tasks' -PercentComplete 75
$beforeTasks = @(Read-CaptureJsonItems -Path (Join-Path $baseline 'scheduled-tasks.json'))
$afterTasks = @(Read-CaptureJsonItems -Path (Join-Path $after 'scheduled-tasks.json'))
$beforeTaskNames = @{}
foreach ($task in $beforeTasks) {
    $beforeTaskNames[("$($task.taskPath)$($task.taskName)").ToLowerInvariant()] = $true
}
$newScheduledTasks = @($afterTasks | Where-Object {
    -not $beforeTaskNames.ContainsKey(("$($_.taskPath)$($_.taskName)").ToLowerInvariant())
})

Write-Progress -Id 11 -Activity 'Computing capture diff' -Status 'Finding shortcuts and uninstall commands' -PercentComplete 90
$newShortcuts = @($addedFiles | Where-Object { $_.path -match '(?i)\.lnk$' })
$uninstallCommands = [System.Collections.ArrayList]::new()
foreach ($entry in (Get-UninstallCommands -RegistryBlocks $afterRegistry)) {
    [void]$uninstallCommands.Add($entry)
}
foreach ($file in $addedFiles) {
    if ($file.path -match '(?i)\\(unins[^\\]*\.exe|uninstall[^\\]*\.exe|[^\\]*\.msi)$') {
        [void]$uninstallCommands.Add([pscustomobject]@{
            source = 'file'
            path = $file.path
            command = '"' + $file.path + '"'
        })
    }
}
$uniqueUninstallCommands = @($uninstallCommands |
    Group-Object command |
    ForEach-Object { $_.Group[0] })
$filteredUninstallCommands = [System.Collections.ArrayList]::new()
$keptUninstallCommands = [System.Collections.ArrayList]::new()
foreach ($entry in $uniqueUninstallCommands) {
    $noiseReason = Get-CaptureUninstallCommandNoiseReason -UninstallCommand $entry
    if ($noiseReason) {
        Add-Member -InputObject $entry -MemberType NoteProperty -Name reason -Value $noiseReason
        [void]$filteredUninstallCommands.Add($entry)
    }
    else {
        [void]$keptUninstallCommands.Add($entry)
    }
}

Write-Progress -Id 11 -Activity 'Computing capture diff' -Status 'Writing manifest' -PercentComplete 95
$manifest = [ordered]@{
    version = 1
    profileName = (Get-Content -LiteralPath (Join-Path $script:CaptureRoot 'session.json') -Raw |
        ConvertFrom-Json).profileName
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    captureContext = [ordered]@{
        baselineUser = $baselineSnapshot.currentUser
        afterUser = $afterSnapshot.currentUser
        sourceUserProfilePath = $afterSnapshot.currentUser.profilePath
        sourceUserSid = $afterSnapshot.currentUser.sid
    }
    safety = [ordered]@{
        destructiveActionsPerformed = $false
        registryDeletionPerformed = $false
        msixGenerated = $false
    }
    addedFiles = @($addedFiles.ToArray())
    addedDirectories = @($addedDirectories.ToArray())
    filteredAddedFiles = @($filteredAddedFiles.ToArray())
    changedFiles = @($changedFiles.ToArray())
    changedRegistryKeys = @($changedRegistryKeys.ToArray())
    filteredRegistryKeys = @($filteredRegistryKeys.ToArray())
    newServices = @($newServices)
    newScheduledTasks = @($newScheduledTasks)
    newShortcuts = @($newShortcuts)
    suspectedUninstallCommands = @($keptUninstallCommands.ToArray())
    filteredUninstallCommands = @($filteredUninstallCommands.ToArray())
}
$manifest | ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Progress -Id 11 -Activity 'Computing capture diff' -Completed

Write-Host ''
Write-Host "Capture finalized to $manifestPath"
Write-Host "Added files:                 $($addedFiles.Count)"
Write-Host "Filtered file noise:         $($filteredAddedFiles.Count)"
Write-Host "Changed registry keys:       $($changedRegistryKeys.Count)"
Write-Host "Filtered registry noise:     $($filteredRegistryKeys.Count)"
Write-Host "New services:                $($newServices.Count)"
Write-Host "New shortcuts:               $($newShortcuts.Count)"
Write-Host "Suspected uninstall commands: $($keptUninstallCommands.Count)"
Write-Host "Filtered uninstall noise:    $($filteredUninstallCommands.Count)"
Write-Host 'No files, registry keys, services, or tasks were deleted.'
