#requires -Version 5.1
# Author: Michal Zygmunt <lahcim@fajne.com>

$ErrorActionPreference = 'Stop'
$installWinget = __INSTALL_WINGET_IN_SANDBOX__
$output = 'C:\WAPCapture\output'
$wingetLogPath = Join-Path $output 'winget-install.log'
$wingetErrorPath = Join-Path $output 'winget-install-error.txt'
New-Item -ItemType Directory -Path $output -Force | Out-Null

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
        $progressPreference = 'SilentlyContinue'
        Write-Host 'Installing winget in Windows Sandbox before baseline capture.'
        Write-Host 'Installing WinGet PowerShell module from PSGallery...'
        Install-PackageProvider -Name NuGet -Force | Out-Null
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
        Write-Host 'Using Repair-WinGetPackageManager cmdlet to bootstrap WinGet...'
        Repair-WinGetPackageManager -AllUsers
        Write-Host 'Done.'
    }
    else {
        Write-Host 'Skipping winget installation in Windows Sandbox before baseline capture.'
    }
}
catch {
    $message = $_ | Out-String
    $message | Set-Content -LiteralPath $wingetErrorPath -Encoding UTF8
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
