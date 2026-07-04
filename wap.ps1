#requires -Version 5.1
# Author: Michal Zygmunt <lahcim@fajne.com>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Command,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]] $Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src/WindowsAutoProfiles.psm1') -Force

$log = $null
$exitCode = 0
$invokeArguments = @($Arguments)
$loggingDisabled = $invokeArguments -contains '--no-log'
$invokeArguments = @($invokeArguments | Where-Object { $_ -ne '--no-log' })

try {
    $log = Start-WapCommandLog -Command $Command -Arguments $invokeArguments -RepositoryRoot $PSScriptRoot -Disabled:$loggingDisabled
    if ($log) {
        [Environment]::SetEnvironmentVariable('WAP_CURRENT_LOG_PATH', $log.path, 'Process')
        $VerbosePreference = 'Continue'
        $InformationPreference = 'Continue'
        $DebugPreference = 'Continue'
    }
    Invoke-WapCli -Command $Command -Arguments $invokeArguments -RepositoryRoot $PSScriptRoot
}
catch {
    $exitCode = 1
    [Console]::Error.WriteLine($_.Exception.Message)
    Write-Verbose ($_.ScriptStackTrace | Out-String)
    if ($log) {
        Write-Host "Command failed. Detailed logs are located at: $($log.path)"
    }
}
finally {
    try {
        if ($log) {
            Invoke-WapLogRetentionCleanup -RepositoryRoot $PSScriptRoot -Root $log.root -RetentionDays $log.retentionDays
        }
        else {
            Invoke-WapLogRetentionCleanup -RepositoryRoot $PSScriptRoot
        }
    }
    catch {
        Write-Warning "Log retention cleanup failed: $($_.Exception.Message)"
    }
    if ($log) {
        Stop-WapCommandLog -Log $log
    }
    [Environment]::SetEnvironmentVariable('WAP_CURRENT_LOG_PATH', $null, 'Process')
}

if ($exitCode -ne 0) {
    exit $exitCode
}
