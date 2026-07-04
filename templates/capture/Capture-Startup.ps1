#requires -Version 5.1
# Author: Michal Zygmunt <lahcim@fajne.com>

$ErrorActionPreference = 'Stop'
$installWinget = __INSTALL_WINGET_IN_SANDBOX__
$output = 'C:\WAPCapture\output'
$wingetPrereqRoot = 'C:\WAPCapture\prereqs\winget'
$wingetLogPath = Join-Path $output 'winget-install.log'
$wingetErrorPath = Join-Path $output 'winget-install-error.txt'
$startupStatusPath = Join-Path $output 'startup-status.json'
New-Item -ItemType Directory -Path $output -Force | Out-Null

Write-Host ''
Write-Host '=== WindowsAutoProfiles Sandbox startup ===' -ForegroundColor Cyan
Write-Host 'This window shows prerequisite setup and baseline capture progress.'
Write-Host "Detailed startup log: $wingetLogPath"
Write-Host ''

function Write-StartupStatus {
    param(
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][bool] $Success,
        [AllowNull()][string] $ErrorMessage
    )

    [pscustomobject]@{
        phase = $Phase
        success = $Success
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        error = $ErrorMessage
        wingetLog = $wingetLogPath
        wingetError = $wingetErrorPath
    } | ConvertTo-Json | Set-Content -LiteralPath $startupStatusPath -Encoding UTF8
}

Write-StartupStatus -Phase 'starting' -Success $false -ErrorMessage $null

$transcriptStarted = $false
try {
    Start-Transcript -LiteralPath $wingetLogPath -Force | Out-Null
    $transcriptStarted = $true
}
catch {
    Write-Warning "Winget setup transcript could not start: $($_.Exception.Message)"
}

try {
    if ($installWinget) {
        Write-StartupStatus -Phase 'installingWinget' -Success $false -ErrorMessage $null
        $progressPreference = 'SilentlyContinue'
        Write-Host 'Phase: installing winget prerequisites.' -ForegroundColor Cyan
        Write-Host 'Installing winget in Windows Sandbox before baseline capture.'
        $vclibs = Join-Path $wingetPrereqRoot 'Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx'
        $vclibsDesktop = Join-Path $wingetPrereqRoot 'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx'
        $windowsAppRuntime = Join-Path $wingetPrereqRoot 'Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64.appx'
        $appInstaller = Join-Path $wingetPrereqRoot 'Microsoft.DesktopAppInstaller.msixbundle'
        foreach ($package in @($vclibs, $vclibsDesktop, $windowsAppRuntime, $appInstaller)) {
            if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
                throw "Required winget bootstrap package was not found: $package"
            }
        }
        Write-Host 'Installing Microsoft.VCLibs dependency...'
        Add-AppxPackage -Path $vclibs
        Write-Host 'Installing Microsoft.VCLibs UWP Desktop dependency...'
        Add-AppxPackage -Path $vclibsDesktop
        Write-Host 'Installing Microsoft Windows App Runtime dependency...'
        Add-AppxPackage -Path $windowsAppRuntime
        Write-Host 'Installing Microsoft App Installer / winget...'
        Add-AppxPackage -Path $appInstaller -DependencyPath @($vclibs, $vclibsDesktop, $windowsAppRuntime)
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) {
            throw 'winget package installation completed, but winget is not available on PATH.'
        }
        Write-Host "Done. winget version: $(& $winget.Source --version)"
    }
    else {
        Write-StartupStatus -Phase 'skippingWinget' -Success $false -ErrorMessage $null
        Write-Host 'Phase: skipping winget prerequisites.' -ForegroundColor Cyan
        Write-Host 'Skipping winget installation in Windows Sandbox before baseline capture.'
    }
    Write-Host ''
    Write-Host 'Phase: starting baseline capture.' -ForegroundColor Cyan
    Write-StartupStatus -Phase 'startingBaseline' -Success $true -ErrorMessage $null
}
catch {
    $message = $_ | Out-String
    $message | Set-Content -LiteralPath $wingetErrorPath -Encoding UTF8
    Write-StartupStatus -Phase 'failed' -Success $false -ErrorMessage $_.Exception.Message
    Write-Host ''
    Write-Host '=== WINGET SETUP FAILED ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Details: $wingetErrorPath"
    throw
}
finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
}

& 'C:\WAPCapture\Capture-Baseline.ps1'
