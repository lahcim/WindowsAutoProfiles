#requires -Version 5.1
# Author: Michal Zygmunt <lahcim@fajne.com>

$ErrorActionPreference = 'Stop'
. 'C:\WAPCapture\Capture-Common.ps1'
Assert-CapturePowerShellVersion -CommandName 'capture baseline'
Assert-CaptureAdministrator -CommandName 'capture baseline' -ScriptPath $PSCommandPath

$baseline = Join-Path $script:CaptureRoot 'baseline'
$output = Join-Path $script:CaptureRoot 'output'
$statusPath = Join-Path $baseline 'baseline-status.json'
$logPath = Join-Path $output 'baseline.log'
$errorPath = Join-Path $output 'baseline-error.txt'
New-Item -ItemType Directory -Path $baseline, $output -Force | Out-Null

$transcriptStarted = $false
try {
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true
}
catch {
    Write-Warning "Transcript could not start: $($_.Exception.Message)"
}

try {
    Write-Host ''
    Write-Host '=== WindowsAutoProfiles baseline capture ===' -ForegroundColor Cyan
    Write-Host 'WindowsAutoProfiles capture: recording baseline.'
    Write-Host 'Do not install applications until BASELINE READY is displayed.'
    Start-Sleep -Seconds 5
    Write-CaptureSnapshot -Destination $baseline
    [pscustomobject]@{
        success = $true
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        error = $null
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== BASELINE READY ===' -ForegroundColor Green
    Write-Host 'The sandbox will remain open. You may now install and configure applications.'
    Write-Host 'When finished, run:'
    Write-Host '  powershell.exe -ExecutionPolicy Bypass -File C:\WAPCapture\Capture-Finalize.ps1'
    Start-Process explorer.exe -ArgumentList 'C:\WAPCapture'
}
catch {
    $message = $_ | Out-String
    [pscustomobject]@{
        success = $false
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        error = $_.Exception.Message
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
    $message | Set-Content -LiteralPath $errorPath -Encoding UTF8
    Write-Host ''
    Write-Host '=== BASELINE FAILED ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Details: $errorPath"
    Start-Process notepad.exe -ArgumentList $errorPath
}
finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
}
