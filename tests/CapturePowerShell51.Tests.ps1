# Author: Michal Zygmunt <lahcim@fajne.com>

Describe 'capture script Windows PowerShell 5.1 compatibility' {
    It 'loads WAP state JSON under Windows PowerShell 5.1' {
        $modulePath = (Resolve-Path "$PSScriptRoot/../src/WindowsAutoProfiles.psm1").Path
        $repo = Join-Path $TestDrive 'wap-state-ps51'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        [ordered]@{
            version = 1
            activeProfile = $null
            profiles = [ordered]@{
                demo = [ordered]@{
                    installedAt = '2026-07-04T00:00:00Z'
                    packages = @()
                }
            }
            registry = [ordered]@{
                enabled = $false
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $repo '.wap-state.json') -Encoding UTF8

        $verifier = Join-Path $TestDrive 'Verify-WapState.ps1'
        @'
param(
    [Parameter(Mandatory)][string] $ModulePath,
    [Parameter(Mandatory)][string] $RepositoryRoot
)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$state = Get-WapState -RepositoryRoot $RepositoryRoot
if (-not $state.Contains('profiles')) {
    throw 'State did not load profiles as a hashtable.'
}
if (-not $state.profiles.Contains('demo')) {
    throw 'State did not preserve profile keys under PowerShell 5.1.'
}
'@ | Set-Content -LiteralPath $verifier -Encoding UTF8

        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $verifier -ModulePath $modulePath -RepositoryRoot $repo 2>&1

        if ($LASTEXITCODE -ne 0) { Write-Host ($output -join "`n") }
        $LASTEXITCODE | Should Be 0
    }

    It 'parses every capture template with the Windows PowerShell 5.1 parser' {
        $templateRoot = (Resolve-Path "$PSScriptRoot/../templates/capture").Path
        $verifier = Join-Path $TestDrive 'Verify-Parser.ps1'
        @'
param([Parameter(Mandatory)][string] $TemplateRoot)
$failed = $false
Get-ChildItem -LiteralPath $TemplateRoot -Filter *.ps1 | ForEach-Object {
    $errors = @()
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName, [ref]$tokens, [ref]$errors
    ) | Out-Null
    if ($errors.Count) {
        $failed = $true
        $errors | ForEach-Object {
            Write-Error "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)"
        }
    }
}
if ($failed) { exit 1 }
'@ | Set-Content -LiteralPath $verifier -Encoding UTF8

        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $verifier -TemplateRoot $templateRoot 2>&1

        if ($LASTEXITCODE -ne 0) { Write-Host ($output -join "`n") }
        $LASTEXITCODE | Should Be 0
    }

    It 'executes filesystem and registry helpers under Windows PowerShell 5.1' {
        $commonPath = (Resolve-Path "$PSScriptRoot/../templates/capture/Capture-Common.ps1").Path
        $workRoot = Join-Path $TestDrive 'ps51-smoke'
        $verifier = Join-Path $TestDrive 'Verify-Helpers.ps1'
        @'
param(
    [Parameter(Mandatory)][string] $CommonPath,
    [Parameter(Mandatory)][string] $WorkRoot
)
$ErrorActionPreference = 'Stop'
. $CommonPath

$currentUser = Get-CaptureCurrentUser
if ([string]::IsNullOrWhiteSpace($currentUser.userName)) {
    throw 'PowerShell 5.1 current-user capture did not include a username.'
}
if ([string]::IsNullOrWhiteSpace($currentUser.profilePath)) {
    throw 'PowerShell 5.1 current-user capture did not include a profile path.'
}
if ($null -eq $currentUser.isElevated) {
    throw 'PowerShell 5.1 current-user capture did not include elevation state.'
}

New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$arrayList = [System.Collections.ArrayList]::new()
[void]$arrayList.Add([pscustomobject]@{ name = 'one' })
[void]$arrayList.Add([pscustomobject]@{ name = 'two' })
$arrayPath = Join-Path $WorkRoot 'array.json'
ConvertTo-CaptureJsonArray -Items $arrayList -Depth 3 |
    Set-Content -LiteralPath $arrayPath -Encoding UTF8
$roundTrip = @(Read-CaptureJsonItems -Path $arrayPath)
if ($roundTrip.Count -ne 2) {
    throw 'PowerShell 5.1 JSON array normalization failed.'
}

$noise = Get-CaptureRegistryNoiseReason -RegistryChange ([pscustomobject]@{
    key = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt'
})
if (-not $noise) {
    throw 'PowerShell 5.1 registry noise classifier did not filter Explorer FileExts.'
}
$notNoise = Get-CaptureRegistryNoiseReason -RegistryChange ([pscustomobject]@{
    key = 'HKEY_CURRENT_USER\Software\Classes\KiCad.kicad_pcb.10.0'
})
if ($notNoise) {
    throw 'PowerShell 5.1 registry noise classifier filtered an app association key.'
}

$fileNoise = Get-CaptureFileNoiseReason -FileChange ([pscustomobject]@{
    path = 'C:\Users\WDAGUtilityAccount\AppData\Local\Microsoft\Edge\User Data\Default\Cache\Cache_Data\data_0'
})
if (-not $fileNoise) {
    throw 'PowerShell 5.1 file noise classifier did not filter Edge cache.'
}
$diagnosticLogNoise = Get-CaptureFileNoiseReason -FileChange ([pscustomobject]@{
    path = 'C:\ProgramData\Microsoft\DiagnosticLogCSP\Collectors\DiagnosticLogCSP_Collector_DeviceProvisioning_2026_7_3.etl'
})
if (-not $diagnosticLogNoise) {
    throw 'PowerShell 5.1 file noise classifier did not filter DiagnosticLogCSP collectors.'
}
$whesvcNoise = Get-CaptureFileNoiseReason -FileChange ([pscustomobject]@{
    path = 'C:\ProgramData\Whesvc\perftrack_summary\perftrack_summary_2026-07-04.json'
})
if (-not $whesvcNoise) {
    throw 'PowerShell 5.1 file noise classifier did not filter Whesvc perftrack summary.'
}
$fileNotNoise = Get-CaptureFileNoiseReason -FileChange ([pscustomobject]@{
    path = 'C:\Users\WDAGUtilityAccount\AppData\Local\Programs\KiCad\10.0\bin\kicad.exe'
})
if ($fileNotNoise) {
    throw 'PowerShell 5.1 file noise classifier filtered a KiCad program file.'
}

$edgeUninstallNoise = Get-CaptureUninstallCommandNoiseReason -UninstallCommand ([pscustomobject]@{
    registryKey = 'HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
    command = '"C:\Program Files (x86)\Microsoft\Edge\Application\149.0.4022.69\Installer\setup.exe" --uninstall'
})
if (-not $edgeUninstallNoise) {
    throw 'PowerShell 5.1 uninstall classifier did not filter Microsoft Edge setup.exe.'
}
$kicadUninstallNoise = Get-CaptureUninstallCommandNoiseReason -UninstallCommand ([pscustomobject]@{
    registryKey = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\KiCad 10.0'
    command = '"C:\Users\WDAGUtilityAccount\AppData\Local\Programs\KiCad\10.0\uninstall.exe"'
})
if ($kicadUninstallNoise) {
    throw 'PowerShell 5.1 uninstall classifier filtered KiCad uninstall command.'
}

$dataRoot = Join-Path $WorkRoot 'data'
$snapshotRoot = Join-Path $WorkRoot 'snapshot'
New-Item -ItemType Directory -Path $dataRoot, $snapshotRoot -Force | Out-Null
'smoke' | Set-Content -LiteralPath (Join-Path $dataRoot 'example.txt') -Encoding UTF8

function Get-CaptureLocations {
    [ordered]@{ Smoke = $dataRoot }
}
Write-FileSnapshot -Destination $snapshotRoot
$files = @(Get-Content -LiteralPath (Join-Path $snapshotRoot 'files.json') -Raw | ConvertFrom-Json)
if (-not ($files | Where-Object { $_.path -like '*example.txt' })) {
    throw 'PowerShell 5.1 filesystem snapshot did not contain the smoke file.'
}

$regPath = Join-Path $WorkRoot 'sample.reg'
@(
    'Windows Registry Editor Version 5.00',
    '',
    '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\Demo]',
    '"UninstallString"="C:\\Demo\\uninstall.exe"'
) | Set-Content -LiteralPath $regPath -Encoding Unicode
$blocks = Get-RegistryBlocks -Path $regPath -Hive 'HKLM'
if ($blocks.Count -ne 1) { throw 'Registry block parsing failed under PowerShell 5.1.' }
$commands = @(Get-UninstallCommands -RegistryBlocks $blocks)
if ($commands.Count -ne 1) { throw 'Uninstall command detection failed under PowerShell 5.1.' }
'@ | Set-Content -LiteralPath $verifier -Encoding UTF8

        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $verifier -CommonPath $commonPath -WorkRoot $workRoot 2>&1

        if ($LASTEXITCODE -ne 0) { Write-Host ($output -join "`n") }
        $LASTEXITCODE | Should Be 0
    }
}
