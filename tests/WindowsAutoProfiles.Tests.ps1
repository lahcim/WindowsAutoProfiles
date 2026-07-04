# Author: Michal Zygmunt <lahcim@fajne.com>

Import-Module "$PSScriptRoot/../src/WindowsAutoProfiles.psm1" -Force

function Write-TestConfig {
    param([string] $RepositoryRoot, [string] $WorkspaceRoot)
    [ordered]@{
        version = 1
        workspaceRoot = $WorkspaceRoot
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RepositoryRoot 'wap.config.json')
}

Describe 'workspace configuration and profile parsing' {
    BeforeEach {
        $script:repo = Join-Path $TestDrive 'repo'
        $script:workspace = Join-Path $TestDrive 'workspaces'
        New-Item -ItemType Directory -Path (Join-Path $script:repo 'profiles/dev') -Force | Out-Null
        Write-TestConfig -RepositoryRoot $script:repo -WorkspaceRoot $script:workspace
        @"
name: dev
apps:
  - id: Git.Git
  - Microsoft.PowerShell
env:
  WAP_PROFILE: dev
  WAP_HOME: `${profileRoot}\Config
path:
  - `${profileRoot}\Apps\bin
  - `${sharedRoot}\bin
projects: `${profileRoot}\Projects
data: `${profileRoot}\Data
downloads: `${profileRoot}\Downloads
cache: `${profileRoot}\Cache
shortcuts:
  - name: Tool
    target: `${profileRoot}\Apps\Tool.exe
"@ | Set-Content -LiteralPath (Join-Path $script:repo 'profiles/dev/profile.yaml')
    }

    It 'derives roots from workspaceRoot and expands profile values' {
        $profile = Import-WapProfile -Name dev -RepositoryRoot $script:repo
        $expectedProfileRoot = [IO.Path]::Combine($script:workspace, 'dev')
        $expectedSharedRoot = [IO.Path]::Combine($script:workspace, '_Shared')
        $profile.workspaceRoot | Should Be $script:workspace
        $profile.profileRoot | Should Be $expectedProfileRoot
        $profile.sharedRoot | Should Be $expectedSharedRoot
        $profile.directories.Config | Should Be ([IO.Path]::Combine($expectedProfileRoot, 'Config'))
        $profile.apps.id | Should Be @('Git.Git', 'Microsoft.PowerShell')
        $profile.env.WAP_HOME | Should Be ([IO.Path]::Combine($expectedProfileRoot, 'Config'))
        ($profile.path -join ';') | Should Match ([regex]::Escape([IO.Path]::Combine($expectedSharedRoot, 'bin')))
        $profile.shortcuts[0].target | Should Be ([IO.Path]::Combine($expectedProfileRoot, 'Apps\Tool.exe'))
    }

    It 'expands environment variables in workspaceRoot' {
        Write-TestConfig -RepositoryRoot $script:repo -WorkspaceRoot '%USERPROFILE%\PortableWorkspaces'
        $config = Get-WapConfig -RepositoryRoot $script:repo
        $config.workspaceRoot | Should Be ([Environment]::ExpandEnvironmentVariables('%USERPROFILE%\PortableWorkspaces'))
    }

    It 'rejects a profile name that differs from its directory' {
        $profilePath = Join-Path $script:repo 'profiles/dev/profile.yaml'
        (Get-Content $profilePath -Raw).Replace('name: dev', 'name: other') |
            Set-Content -LiteralPath $profilePath
        $message = $null
        try { Import-WapProfile -Name dev -RepositoryRoot $script:repo }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'does not match directory name'
    }

    It 'rejects unsafe profile names' {
        $message = $null
        try { Import-WapProfile -Name '../outside' -RepositoryRoot $script:repo }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'Invalid profile name'
    }
}

Describe 'state, init, and capture' {
    It 'shows help and examples from the external examples file' {
        $repo = Join-Path $TestDrive 'help-examples'
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs') -Force | Out-Null
        'External example content with .\wap.ps1 init' | Set-Content -LiteralPath (Join-Path $repo 'docs\examples.md')

        $help = (Invoke-WapCli -Command '--help' -Arguments @() -RepositoryRoot $repo *>&1 | Out-String)
        $examples = (Invoke-WapCli -Command '--examples' -Arguments @() -RepositoryRoot $repo *>&1 | Out-String)

        $help | Should Match '--examples'
        $examples | Should Match 'External example content'
        $examples | Should Match ([regex]::Escape('.\wap.ps1 init'))
    }

    It 'reports incomplete commands with suggested completions' {
        $repo = Join-Path $TestDrive 'incomplete-commands'
        New-Item -ItemType Directory -Path $repo | Out-Null

        $message = $null
        try { Invoke-WapCli -Command config -Arguments @('') -RepositoryRoot $repo }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'Command is incomplete'
        $message | Should Match ([regex]::Escape('.\wap.ps1 config show'))
        $message | Should Match ([regex]::Escape('.\wap.ps1 config set profilesRoot <path>'))

        $message = $null
        try { Invoke-WapCli -Command config -Arguments @('set') -RepositoryRoot $repo }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'Command is incomplete'
        $message | Should Match ([regex]::Escape('.\wap.ps1 config set configPath <path>'))

        $message = $null
        try { Invoke-WapCli -Command capture -Arguments @() -RepositoryRoot $repo }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'Command is incomplete'
        $message | Should Match ([regex]::Escape('.\wap.ps1 capture start <name>'))
    }

    It 'initializes config and state idempotently without overwriting config' {
        $repo = Join-Path $TestDrive 'init'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        (Join-Path $repo 'wap.config.json') | Should Exist
        (Join-Path $repo 'wap.settings.json') | Should Exist
        $customRoot = Join-Path $TestDrive 'custom-workspaces'
        Write-TestConfig -RepositoryRoot $repo -WorkspaceRoot $customRoot
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        $state = Get-WapState -RepositoryRoot $repo
        $config = Get-WapConfig -RepositoryRoot $repo
        $state.version | Should Be 1
        $state.profiles.Count | Should Be 0
        $state.registry.enabled | Should Be $false
        $config.workspaceRoot | Should Be $customRoot
    }

    It 'uses default settings when optional config keys are missing' {
        $repo = Join-Path $TestDrive 'minimal-config'
        New-Item -ItemType Directory -Path $repo | Out-Null
        [ordered]@{
            version = 1
            configPath = 'wap.settings.json'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'wap.config.json') -Encoding UTF8
        [ordered]@{} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'wap.settings.json') -Encoding UTF8

        $config = Get-WapConfig -RepositoryRoot $repo
        $shown = Show-WapConfig -RepositoryRoot $repo | Out-String

        $config.version | Should Be 1
        $config.workspaceRoot | Should Be ([Environment]::ExpandEnvironmentVariables('%USERPROFILE%\Workspaces'))
        $config.profilesRoot | Should Be (Join-Path $repo 'profiles')
        $config.loggingEnabled | Should Be $true
        $config.loggingRetentionDays | Should Be 30
        $config.logRoot | Should Be (Join-Path $repo '.logs')
        $config.sandboxInstallWinget | Should Be $true
        $shown | Should Match 'workspaceRoot\s+:\s+%USERPROFILE%\\Workspaces'
        $shown | Should Match 'profilesRoot\s+:\s+profiles'
        $shown | Should Match 'logging\.root\s+:\s+\.logs'
        $shown | Should Match 'sandbox\.installWinget\s+:\s+True'
    }

    It 'installs prerequisites during init by default and can skip them' {
        $repo = Join-Path $TestDrive 'init-prereqs'
        New-Item -ItemType Directory -Path $repo | Out-Null
        $global:wingetChecks = 0
        Mock Test-WapWingetAvailable {
            $global:wingetChecks++
            return ($global:wingetChecks -ge 2)
        } -ModuleName WindowsAutoProfiles
        Mock Add-AppxPackage {} -ModuleName WindowsAutoProfiles
        Mock Install-PackageProvider {} -ModuleName WindowsAutoProfiles
        Mock Install-Module {} -ModuleName WindowsAutoProfiles
        Mock Import-Module {} -ModuleName WindowsAutoProfiles

        Invoke-WapCli -Command init -Arguments @() -RepositoryRoot $repo

        (Join-Path $repo 'wap.config.json') | Should Exist
        Assert-MockCalled Add-AppxPackage 1 -ModuleName WindowsAutoProfiles
        Assert-MockCalled Install-Module 0 -ModuleName WindowsAutoProfiles

        $nullArgsRepo = Join-Path $TestDrive 'init-null-args'
        New-Item -ItemType Directory -Path $nullArgsRepo | Out-Null
        Invoke-WapCli -Command init -Arguments $null -RepositoryRoot $nullArgsRepo
        (Join-Path $nullArgsRepo 'wap.config.json') | Should Exist

        $skipRepo = Join-Path $TestDrive 'init-skip-prereqs'
        New-Item -ItemType Directory -Path $skipRepo | Out-Null
        Invoke-WapCli -Command init -Arguments @('--skip-prereqs') -RepositoryRoot $skipRepo
        (Join-Path $skipRepo 'wap.config.json') | Should Exist
        Assert-MockCalled Add-AppxPackage 1 -ModuleName WindowsAutoProfiles
        Remove-Variable -Name wingetChecks -Scope Global -ErrorAction SilentlyContinue
    }

    It 'supports an external full config and external profilesRoot with runtime environment expansion' {
        $repo = Join-Path $TestDrive 'external-config'
        $configDirectory = Join-Path $TestDrive 'external-config-store'
        $workspace = Join-Path $TestDrive 'external-workspaces'
        $profiles = Join-Path $TestDrive 'external-profiles'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        [Environment]::SetEnvironmentVariable('WAP_TEST_CONFIG_DIR', $configDirectory, 'Process')
        [Environment]::SetEnvironmentVariable('WAP_TEST_WORKSPACES', $workspace, 'Process')
        [Environment]::SetEnvironmentVariable('WAP_TEST_PROFILES', $profiles, 'Process')

        try {
            Invoke-WapCli -Command config -Arguments @('set', 'configPath', '%WAP_TEST_CONFIG_DIR%\wap.full.json') -RepositoryRoot $repo
            Invoke-WapCli -Command config -Arguments @('set', 'workspaceRoot', '%WAP_TEST_WORKSPACES%') -RepositoryRoot $repo
            Invoke-WapCli -Command config -Arguments @('set', 'profilesRoot', '%WAP_TEST_PROFILES%') -RepositoryRoot $repo

            $fullConfigPath = Join-Path $configDirectory 'wap.full.json'
            $bootstrap = Get-Content -LiteralPath (Join-Path $repo 'wap.config.json') -Raw | ConvertFrom-Json
            $rawFullConfig = Get-Content -LiteralPath $fullConfigPath -Raw | ConvertFrom-Json
            $config = Get-WapConfig -RepositoryRoot $repo

            $bootstrap.configPath | Should Be '%WAP_TEST_CONFIG_DIR%\wap.full.json'
            $rawFullConfig.workspaceRoot | Should Be '%WAP_TEST_WORKSPACES%'
            $rawFullConfig.profilesRoot | Should Be '%WAP_TEST_PROFILES%'
            $config.source | Should Be $fullConfigPath
            $config.workspaceRoot | Should Be $workspace
            $config.profilesRoot | Should Be $profiles

            New-Item -ItemType Directory -Path (Join-Path $profiles 'cloud') -Force | Out-Null
            @('name: cloud', 'apps:') | Set-Content -LiteralPath (Join-Path $profiles 'cloud\profile.yaml')
            $profile = Import-WapProfile -Name cloud -RepositoryRoot $repo
            $profile.profileRoot | Should Be ([IO.Path]::Combine($workspace, 'cloud'))
        }
        finally {
            [Environment]::SetEnvironmentVariable('WAP_TEST_CONFIG_DIR', $null, 'Process')
            [Environment]::SetEnvironmentVariable('WAP_TEST_WORKSPACES', $null, 'Process')
            [Environment]::SetEnvironmentVariable('WAP_TEST_PROFILES', $null, 'Process')
        }
    }

    It 'supports configurable bootstrap and logging roots with runtime environment expansion' {
        $repo = Join-Path $TestDrive 'bootstrap-log-root'
        $bootstrapDirectory = Join-Path $TestDrive 'bootstrap-store'
        $settingsDirectory = Join-Path $TestDrive 'settings-store'
        $logsDirectory = Join-Path $TestDrive 'custom-logs'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        [Environment]::SetEnvironmentVariable('WAP_TEST_BOOTSTRAP_DIR', $bootstrapDirectory, 'Process')
        [Environment]::SetEnvironmentVariable('WAP_TEST_SETTINGS_DIR', $settingsDirectory, 'Process')
        [Environment]::SetEnvironmentVariable('WAP_TEST_LOGS_DIR', $logsDirectory, 'Process')

        try {
            Invoke-WapCli -Command config -Arguments @('set', 'bootstrapConfigPath', '%WAP_TEST_BOOTSTRAP_DIR%\wap.bootstrap.json') -RepositoryRoot $repo
            Invoke-WapCli -Command config -Arguments @('set', 'configPath', '%WAP_TEST_SETTINGS_DIR%\wap.settings.json') -RepositoryRoot $repo
            Invoke-WapCli -Command config -Arguments @('set', 'logging.root', '%WAP_TEST_LOGS_DIR%') -RepositoryRoot $repo

            $localBootstrap = Get-Content -LiteralPath (Join-Path $repo 'wap.config.json') -Raw | ConvertFrom-Json
            $externalBootstrapPath = Join-Path $bootstrapDirectory 'wap.bootstrap.json'
            $externalBootstrap = Get-Content -LiteralPath $externalBootstrapPath -Raw | ConvertFrom-Json
            $fullConfigPath = Join-Path $settingsDirectory 'wap.settings.json'
            $rawFullConfig = Get-Content -LiteralPath $fullConfigPath -Raw | ConvertFrom-Json
            $config = Get-WapConfig -RepositoryRoot $repo
            $shown = Show-WapConfig -RepositoryRoot $repo | Out-String

            $localBootstrap.bootstrapConfigPath | Should Be '%WAP_TEST_BOOTSTRAP_DIR%\wap.bootstrap.json'
            $externalBootstrap.configPath | Should Be '%WAP_TEST_SETTINGS_DIR%\wap.settings.json'
            $rawFullConfig.logging.root | Should Be '%WAP_TEST_LOGS_DIR%'
            $config.localBootstrap | Should Be (Join-Path $repo 'wap.config.json')
            $config.bootstrap | Should Be $externalBootstrapPath
            $config.source | Should Be $fullConfigPath
            $config.logRoot | Should Be $logsDirectory
            Test-Path -LiteralPath $logsDirectory -PathType Container | Should Be $false
            $shown | Should Match 'bootstrapConfigPath'
            $shown | Should Match 'logging\.root'
            $shown | Should Not Match 'LoggingRoot'
            $shown | Should Match 'resolved\.bootstrapConfigPath'
            $shown | Should Match 'resolved\.logging\.root'
        }
        finally {
            [Environment]::SetEnvironmentVariable('WAP_TEST_BOOTSTRAP_DIR', $null, 'Process')
            [Environment]::SetEnvironmentVariable('WAP_TEST_SETTINGS_DIR', $null, 'Process')
            [Environment]::SetEnvironmentVariable('WAP_TEST_LOGS_DIR', $null, 'Process')
        }
    }

    It 'shows and sets workspaceRoot through the CLI' {
        $repo = Join-Path $TestDrive 'config-cli'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        $newRoot = Join-Path $TestDrive 'configured-workspaces'

        Invoke-WapCli -Command config -Arguments @('set', 'workspaceRoot', $newRoot) -RepositoryRoot $repo
        $config = Get-WapConfig -RepositoryRoot $repo
        $shown = Show-WapConfig -RepositoryRoot $repo | Out-String

        $config.workspaceRoot | Should Be $newRoot
        $shown | Should Match ([regex]::Escape($newRoot))
        $shown | Should Match 'Configurable settings'
        $shown | Should Match 'Dynamic resolved settings'
        $shown | Should Match 'resolved\.workspaceRoot'
    }

    It 'rejects attempts to set dynamic resolved configuration values with guidance' {
        $repo = Join-Path $TestDrive 'resolved-config-key'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs

        $message = $null
        try {
            Invoke-WapCli -Command config -Arguments @('set', 'ResolvedConfigPath', '%USERPROFILE%\settings.json') -RepositoryRoot $repo
        }
        catch { $message = $_.Exception.Message }

        $message | Should Match 'dynamic and read-only'
        $message | Should Match "Set 'configPath' instead"
    }

    It 'shows and sets logging configuration through the CLI' {
        $repo = Join-Path $TestDrive 'logging-config-cli'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs

        Invoke-WapCli -Command config -Arguments @('set', 'logging.enabled', 'false') -RepositoryRoot $repo
        Invoke-WapCli -Command config -Arguments @('set', 'logging.retentionDays', '0') -RepositoryRoot $repo
        $config = Get-WapConfig -RepositoryRoot $repo
        $shown = Show-WapConfig -RepositoryRoot $repo | Out-String

        $config.loggingEnabled | Should Be $false
        $config.loggingRetentionDays | Should Be 0
        $shown | Should Match 'logging\.enabled\s+:\s+False'
        $shown | Should Match 'logging\.retentionDays\s+:\s+0'
    }

    It 'cleans generated logs while keeping the current command log' {
        $repo = Join-Path $TestDrive 'logs-cleanup'
        New-Item -ItemType Directory -Path (Join-Path $repo '.logs') -Force | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        $oldLog = Join-Path $repo '.logs/old.log'
        $currentLog = Join-Path $repo '.logs/current.log'
        'old' | Set-Content -LiteralPath $oldLog
        'current' | Set-Content -LiteralPath $currentLog
        [Environment]::SetEnvironmentVariable('WAP_CURRENT_LOG_PATH', $currentLog, 'Process')

        try {
            Invoke-WapCli -Command logs -Arguments @('cleanup') -RepositoryRoot $repo
        }
        finally {
            [Environment]::SetEnvironmentVariable('WAP_CURRENT_LOG_PATH', $null, 'Process')
        }

        $oldLog | Should Not Exist
        $currentLog | Should Exist
    }

    It 'rejects a relative workspaceRoot from the CLI' {
        $repo = Join-Path $TestDrive 'invalid-config-cli'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        $message = $null
        try {
            Invoke-WapCli -Command config -Arguments @('set', 'workspaceRoot', 'relative\path') -RepositoryRoot $repo
        }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'must resolve to an absolute path'
    }
    It 'creates a portable capture without requiring winget' {
        $repo = Join-Path $TestDrive 'capture'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' } -ModuleName WindowsAutoProfiles
        New-WapCapture -Name fresh -RepositoryRoot $repo
        $path = Join-Path $repo 'profiles/fresh/profile.yaml'
        $path | Should Exist
        $yaml = Get-Content $path -Raw
        $yaml | Should Match 'name: fresh'
        $yaml | Should Match 'profile winget add <profile> <packageId>'
        $yaml | Should Not Match 'Git\.Git'
        $yaml | Should Match '\$\{profileRoot\}\\Apps\\bin'
        $yaml | Should Not Match '^[A-Za-z]:\\'
    }

    It 'creates an empty placeholder profile under the configured profilesRoot' {
        $repo = Join-Path $TestDrive 'profile-new'
        $profiles = Join-Path $TestDrive 'profile-new-definitions'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        Invoke-WapCli -Command config -Arguments @('set', 'profilesRoot', $profiles) -RepositoryRoot $repo

        Invoke-WapCli -Command profile -Arguments @('new', 'developer') -RepositoryRoot $repo
        $profilePath = Join-Path $profiles 'developer\profile.yaml'
        $profilePath | Should Exist
        $yaml = Get-Content -LiteralPath $profilePath -Raw
        $yaml | Should Match 'name: developer'
        $yaml | Should Match 'apps:'
        $yaml | Should Match 'env:'
        $yaml | Should Match 'path:'
        $yaml | Should Match '\$\{profileRoot\}\\Projects'

        $profile = Import-WapProfile -Name developer -RepositoryRoot $repo
        $profile.name | Should Be 'developer'

        Invoke-WapCli -Command profile -Arguments @('new', 'designer', '-WhatIf') -RepositoryRoot $repo
        (Join-Path $profiles 'designer\profile.yaml') | Should Not Exist
    }
}

Describe 'profile status' {
    It 'shows available, inactive, and active profiles through status and list' {
        $repo = Join-Path $TestDrive 'status'
        $workspace = Join-Path $TestDrive 'status-workspaces'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        Write-TestConfig -RepositoryRoot $repo -WorkspaceRoot $workspace
        foreach ($name in @('available', 'inactive', 'active')) {
            $profileDirectory = Join-Path $repo "profiles/$name"
            New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
            @("name: $name", 'apps:') | Set-Content -LiteralPath (Join-Path $profileDirectory 'profile.yaml')
        }
        $state = Get-WapState -RepositoryRoot $repo
        foreach ($name in @('inactive', 'active')) {
            $state.profiles[$name] = [ordered]@{
                installed = $true
                profileRoot = Join-Path $workspace $name
                packages = @()
                installedPackages = @()
                shortcuts = @()
                activation = $null
            }
        }
        $state.activeProfile = 'active'
        $state.profiles.active.activation = [ordered]@{ environment = [ordered]@{}; pathAdded = @() }
        $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $repo '.wap-state.json')

        $status = (Invoke-WapCli -Command profile -Arguments @('status') -RepositoryRoot $repo *>&1 | Out-String)
        $list = (Invoke-WapCli -Command profile -Arguments @('list') -RepositoryRoot $repo *>&1 | Out-String)

        $status | Should Match 'available\s+False\s+Not installed'
        $status | Should Match 'inactive\s+True\s+Inactive'
        $status | Should Match 'active\s+True\s+Active'
        $status | Should Match 'Active profile:\s+active'
        $list | Should Match 'inactive\s+True\s+Inactive'
    }
}
Describe 'interactive Windows Sandbox capture' {
    It 'generates the mounted sandbox session and launches it' {
        $repo = Join-Path $TestDrive 'sandbox-capture'
        New-Item -ItemType Directory -Path (Join-Path $repo 'templates') -Force | Out-Null
        Copy-Item -LiteralPath "$PSScriptRoot/../templates/capture" -Destination (Join-Path $repo 'templates/capture') -Recurse
        Mock Get-Command { [pscustomobject]@{ Source = 'WindowsSandbox.exe' } } `
            -ParameterFilter { $Name -eq 'WindowsSandbox.exe' } -ModuleName WindowsAutoProfiles
        Mock Save-WapSandboxWingetPrerequisites {} -ModuleName WindowsAutoProfiles
        Mock Start-Process {
            $wsbPath = if ($ArgumentList -is [array]) { $ArgumentList[0] } else { $ArgumentList }
            $captureRoot = Split-Path -Parent $wsbPath
            $baselineRoot = Join-Path $captureRoot 'baseline'
            New-Item -ItemType Directory -Path $baselineRoot -Force | Out-Null
            [ordered]@{
                success = $true
                completedAt = (Get-Date).ToUniversalTime().ToString('o')
                error = $null
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $baselineRoot 'baseline-status.json') -Encoding UTF8
            [ordered]@{
                capturedAt = (Get-Date).ToUniversalTime().ToString('o')
                computerName = 'SANDBOX'
                currentUser = [ordered]@{
                    qualifiedName = 'SANDBOX\WDAGUtilityAccount'
                    profilePath = 'C:\Users\WDAGUtilityAccount'
                }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $baselineRoot 'snapshot.json') -Encoding UTF8
            $process = New-Object psobject -Property @{ HasExited = $true }
            $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
            return $process
        } -ModuleName WindowsAutoProfiles

        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        $output = (Start-WapInteractiveCapture -Name demo -RepositoryRoot $repo *>&1 | Out-String)

        $captureRoot = Join-Path $repo '.capture/demo'
        foreach ($item in @(
            'baseline', 'after', 'output', 'sandbox.wsb', 'Capture-Startup.ps1', 'Capture-Baseline.ps1',
            'Capture-Finalize.ps1', 'Capture-Common.ps1', 'capture-filters.json', 'session.json'
        )) {
            (Join-Path $captureRoot $item) | Should Exist
        }
        $wsb = Get-Content -LiteralPath (Join-Path $captureRoot 'sandbox.wsb') -Raw
        $wsb | Should Match ([regex]::Escape($captureRoot))
        $wsb | Should Match ([regex]::Escape('<SandboxFolder>C:\WAPCapture</SandboxFolder>'))
        $wsb | Should Match ([regex]::Escape('<ReadOnly>false</ReadOnly>'))
        $wsb | Should Match 'Capture-Startup.ps1'
        $wsb | Should Match '-NoExit'
        (Get-Content (Join-Path $captureRoot 'Capture-Startup.ps1') -Raw) | Should Match ([regex]::Escape('$installWinget = $true'))
        (Get-Content (Join-Path $captureRoot 'Capture-Startup.ps1') -Raw) | Should Match 'Sandbox startup'
        (Get-Content (Join-Path $captureRoot 'Capture-Startup.ps1') -Raw) | Should Match 'Add-AppxPackage -Path'
        (Get-Content (Join-Path $captureRoot 'Capture-Startup.ps1') -Raw) | Should Match 'Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx'
        (Get-Content (Join-Path $captureRoot 'Capture-Startup.ps1') -Raw) | Should Match 'Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64.appx'
        (Get-Content (Join-Path $captureRoot 'Capture-Startup.ps1') -Raw) | Should Not Match 'Install-Module'
        (Get-Content (Join-Path $captureRoot 'Capture-Baseline.ps1') -Raw) | Should Match 'Write-CaptureSnapshot'
        (Get-Content (Join-Path $captureRoot 'Capture-Baseline.ps1') -Raw) | Should Match 'BASELINE READY'
        (Get-Content (Join-Path $captureRoot 'Capture-Baseline.ps1') -Raw) | Should Match 'Capture-Baseline.ps1'
        (Get-Content (Join-Path $captureRoot 'Capture-Baseline.ps1') -Raw) | Should Match 'baseline-status.json'
        (Get-Content (Join-Path $captureRoot 'Capture-Common.ps1') -Raw) | Should Match 'Get-Service fallback'
        (Get-Content (Join-Path $captureRoot 'Capture-Common.ps1') -Raw) | Should Match 'Get-CaptureCurrentUser'
        (Get-Content (Join-Path $captureRoot 'Capture-Finalize.ps1') -Raw) | Should Match 'capture-manifest.json'
        (Get-Content (Join-Path $captureRoot 'Capture-Finalize.ps1') -Raw) | Should Match 'captureContext'
        $output | Should Match 'BASELINE READY'
        $output | Should Match 'Optional: if you install tools that should be part of the baseline'
        $output | Should Match 'Capture-Baseline\.ps1'
        $output | Should Match 'Capture-Finalize\.ps1'
        $output | Should Match 'WDAGUtilityAccount'
        $output | Should Match 'Sandbox winget bootstrap:\s+enabled'
        $session = Get-Content -LiteralPath (Join-Path $captureRoot 'session.json') -Raw | ConvertFrom-Json
        $session.sandbox.installWinget | Should Be $true
        Assert-MockCalled Save-WapSandboxWingetPrerequisites 1 -ModuleName WindowsAutoProfiles -Scope It
        Assert-MockCalled Start-Process 1 -ModuleName WindowsAutoProfiles
    }

    It 'can skip sandbox winget bootstrap for capture start' {
        $repo = Join-Path $TestDrive 'sandbox-capture-no-winget'
        New-Item -ItemType Directory -Path (Join-Path $repo 'templates') -Force | Out-Null
        Copy-Item -LiteralPath "$PSScriptRoot/../templates/capture" -Destination (Join-Path $repo 'templates/capture') -Recurse
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        Mock Save-WapSandboxWingetPrerequisites {} -ModuleName WindowsAutoProfiles
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'WindowsSandbox.exe' } -ModuleName WindowsAutoProfiles

        $output = (Invoke-WapCli -Command capture -Arguments @('start', 'demo', '--no-winget') -RepositoryRoot $repo *>&1 | Out-String)

        $captureRoot = Join-Path $repo '.capture/demo'
        (Get-Content (Join-Path $captureRoot 'Capture-Startup.ps1') -Raw) | Should Match ([regex]::Escape('$installWinget = $false'))
        $session = Get-Content -LiteralPath (Join-Path $captureRoot 'session.json') -Raw | ConvertFrom-Json
        $session.sandbox.installWinget | Should Be $false
        $output | Should Match 'Sandbox winget bootstrap:\s+disabled'
        Assert-MockCalled Save-WapSandboxWingetPrerequisites 0 -ModuleName WindowsAutoProfiles -Scope It
    }

    It 'fails fast when sandbox winget bootstrap writes an error' {
        $repo = Join-Path $TestDrive 'sandbox-capture-winget-failure'
        New-Item -ItemType Directory -Path (Join-Path $repo 'templates') -Force | Out-Null
        Copy-Item -LiteralPath "$PSScriptRoot/../templates/capture" -Destination (Join-Path $repo 'templates/capture') -Recurse
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        Mock Get-Command { [pscustomobject]@{ Source = 'WindowsSandbox.exe' } } `
            -ParameterFilter { $Name -eq 'WindowsSandbox.exe' } -ModuleName WindowsAutoProfiles
        Mock Save-WapSandboxWingetPrerequisites {} -ModuleName WindowsAutoProfiles
        Mock Start-Process {
            $wsbPath = if ($ArgumentList -is [array]) { $ArgumentList[0] } else { $ArgumentList }
            $captureRoot = Split-Path -Parent $wsbPath
            $outputRoot = Join-Path $captureRoot 'output'
            New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
            'Access is denied. (Exception from HRESULT: 0x80070005 (E_ACCESSDENIED))' |
                Set-Content -LiteralPath (Join-Path $outputRoot 'winget-install-error.txt') -Encoding UTF8
            [ordered]@{
                phase = 'failed'
                success = $false
                updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                error = 'Access is denied.'
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'startup-status.json') -Encoding UTF8
            $process = New-Object psobject -Property @{ HasExited = $false }
            $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
            return $process
        } -ModuleName WindowsAutoProfiles

        $message = $null
        try { Start-WapInteractiveCapture -Name demo -RepositoryRoot $repo }
        catch { $message = $_.Exception.Message }

        $message | Should Match 'Sandbox winget setup failed before baseline capture'
        $message | Should Match 'winget-install\.log'
        $message | Should Match 'winget-install-error\.txt'
        $message | Should Match 'Access is denied'
    }

    It 'summarizes and validates a dry-run capture manifest' {
        $repo = Join-Path $TestDrive 'capture-diff'
        $output = Join-Path $repo '.capture/demo/output'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        [ordered]@{
            version = 1
            profileName = 'demo'
            safety = [ordered]@{
                destructiveActionsPerformed = $false
                registryDeletionPerformed = $false
                msixGenerated = $false
            }
            addedFiles = @([ordered]@{ scope = 'ProgramFiles'; path = 'C:\Program Files\Demo\demo.exe' })
            changedRegistryKeys = @([ordered]@{ change = 'Added'; hive = 'HKLM'; key = 'Software\Demo' })
            newServices = @([ordered]@{ Name = 'DemoSvc'; DisplayName = 'Demo'; StartMode = 'Auto'; PathName = 'demo.exe' })
            newWingetPackages = @([ordered]@{ id = 'Demo.Package'; source = 'winget' })
            newShortcuts = @([ordered]@{ scope = 'CommonStartMenu'; path = 'C:\Start Menu\Demo.lnk' })
            suspectedUninstallCommands = @([ordered]@{ source = 'registry'; command = 'uninstall.exe' })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'capture-manifest.json')
        @(
            'name: demo'
            'apps:'
            '  - id: Demo.Package'
            '    source: winget'
            '    enabled: true'
        ) | Set-Content -LiteralPath (Join-Path $output 'profile.yaml')

        $diff = (Invoke-WapCli -Command capture -Arguments @('diff', 'demo') -RepositoryRoot $repo *>&1 | Out-String)
        $validate = (Invoke-WapCli -Command capture -Arguments @('validate', 'demo') -RepositoryRoot $repo *>&1 | Out-String)

        $diff | Should Match 'Added files:\s+1'
        $diff | Should Match 'Changed registry keys:\s+1'
        $diff | Should Match 'New services:\s+1'
        $diff | Should Match 'New winget packages:\s+1'
        $diff | Should Match 'New shortcuts:\s+1'
        $diff | Should Match 'Suspected uninstall commands:\s+1'
        $diff | Should Match 'nothing was deleted and no MSIX was generated'
        $validate | Should Match 'manifest validated'
    }

    It 'rejects a capture profile missing manifest winget package references' {
        $repo = Join-Path $TestDrive 'capture-profile-validation'
        $output = Join-Path $repo '.capture/demo/output'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        [ordered]@{
            version = 1
            profileName = 'demo'
            safety = [ordered]@{
                destructiveActionsPerformed = $false
                registryDeletionPerformed = $false
                msixGenerated = $false
            }
            addedFiles = @()
            changedRegistryKeys = @()
            newWingetPackages = @([ordered]@{ id = 'Demo.Package'; source = 'winget' })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'capture-manifest.json')
        @('name: demo', 'apps:') | Set-Content -LiteralPath (Join-Path $output 'profile.yaml')

        $message = $null
        try { Invoke-WapCli -Command capture -Arguments @('validate', 'demo') -RepositoryRoot $repo }
        catch { $message = $_.Exception.Message }

        $message | Should Match "missing winget package 'Demo\.Package'"
    }

    It 'reapplies capture filters to an existing manifest' {
        $repo = Join-Path $TestDrive 'capture-applyfilter'
        $captureRoot = Join-Path $repo '.capture/demo'
        $output = Join-Path $captureRoot 'output'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        Copy-Item -LiteralPath "$PSScriptRoot/../templates/capture/capture-filters.json" -Destination (Join-Path $captureRoot 'capture-filters.json')
        [ordered]@{
            version = 1
            profileName = 'demo'
            safety = [ordered]@{
                destructiveActionsPerformed = $false
                registryDeletionPerformed = $false
                msixGenerated = $false
            }
            addedFiles = @(
                [ordered]@{ scope = 'AppDataLocal'; path = 'C:\Users\WDAGUtilityAccount\AppData\Local\Microsoft\Edge\User Data\Default\Cache\Cache_Data\data_0'; itemType = 'File' },
                [ordered]@{ scope = 'AppDataLocal'; path = 'C:\Users\WDAGUtilityAccount\AppData\Local\Programs\KiCad\10.0\bin\kicad.exe'; itemType = 'File' }
            )
            addedDirectories = @()
            changedRegistryKeys = @(
                [ordered]@{ change = 'Added'; hive = 'HKCU'; key = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt' },
                [ordered]@{ change = 'Added'; hive = 'HKCU'; key = 'HKEY_CURRENT_USER\Software\Classes\KiCad.kicad_pcb.10.0' }
            )
            newServices = @()
            newShortcuts = @()
            suspectedUninstallCommands = @(
                [ordered]@{ source = 'registry'; registryKey = 'HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'; command = '"C:\Program Files (x86)\Microsoft\Edge\Application\149.0.4022.69\Installer\setup.exe" --uninstall' },
                [ordered]@{ source = 'file'; path = 'C:\Users\WDAGUtilityAccount\AppData\Local\Programs\KiCad\10.0\uninstall.exe'; command = '"C:\Users\WDAGUtilityAccount\AppData\Local\Programs\KiCad\10.0\uninstall.exe"' }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'capture-manifest.json')

        $result = (Invoke-WapCli -Command capture -Arguments @('applyfilter', 'demo') -RepositoryRoot $repo *>&1 | Out-String)
        $manifest = Get-Content -LiteralPath (Join-Path $output 'capture-manifest.json') -Raw | ConvertFrom-Json

        @($manifest.addedFiles).Count | Should Be 1
        @($manifest.filteredAddedFiles).Count | Should Be 1
        @($manifest.changedRegistryKeys).Count | Should Be 1
        @($manifest.filteredRegistryKeys).Count | Should Be 1
        @($manifest.suspectedUninstallCommands).Count | Should Be 1
        @($manifest.filteredUninstallCommands).Count | Should Be 1
        (Join-Path $output 'capture-manifest.before-applyfilter.json') | Should Exist
        $result | Should Match 'Filtered file noise:\s+1'
        $result | Should Match 'Filtered registry noise:\s+1'
        $result | Should Match 'Filtered uninstall noise:\s+1'
    }

    It 'supports WhatIf and deletes only the named capture session' {
        $repo = Join-Path $TestDrive 'remove-capture'
        $captureRoot = Join-Path $repo '.capture/demo'
        $otherCaptureRoot = Join-Path $repo '.capture/other'
        $profileRoot = Join-Path $repo 'profiles/demo'
        New-Item -ItemType Directory -Path $captureRoot, $otherCaptureRoot, $profileRoot -Force | Out-Null
        'capture' | Set-Content -LiteralPath (Join-Path $captureRoot 'session.json')
        'other' | Set-Content -LiteralPath (Join-Path $otherCaptureRoot 'session.json')
        @('name: demo', 'apps:') | Set-Content -LiteralPath (Join-Path $profileRoot 'profile.yaml')

        Invoke-WapCli -Command capture -Arguments @('remove', 'demo', '-WhatIf') -RepositoryRoot $repo
        $captureRoot | Should Exist
        Invoke-WapCli -Command capture -Arguments @('remove', 'demo') -RepositoryRoot $repo
        $captureRoot | Should Not Exist
        $otherCaptureRoot | Should Exist
        $profileRoot | Should Exist
    }

    It 'lists and renames standalone capture sessions' {
        $repo = Join-Path $TestDrive 'list-rename-captures'
        $captureRoot = Join-Path $repo '.capture/kicad'
        $output = Join-Path $captureRoot 'output'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        [ordered]@{
            version = 1
            profileName = 'kicad'
            createdAt = '2026-01-01T00:00:00Z'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $captureRoot 'session.json') -Encoding UTF8
        [ordered]@{
            version = 1
            profileName = 'kicad'
            safety = [ordered]@{
                destructiveActionsPerformed = $false
                registryDeletionPerformed = $false
                msixGenerated = $false
            }
            addedFiles = @()
            changedRegistryKeys = @()
            newServices = @()
            newShortcuts = @()
            suspectedUninstallCommands = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'capture-manifest.json') -Encoding UTF8

        $list = (Invoke-WapCli -Command capture -Arguments @('list') -RepositoryRoot $repo *>&1 | Out-String)
        $list | Should Match ([regex]::Escape((Join-Path $repo '.capture')))
        $list | Should Match 'kicad'
        $list | Should Match 'Finalized'

        Invoke-WapCli -Command capture -Arguments @('rename', 'kicad', 'electronics-kicad', '-WhatIf') -RepositoryRoot $repo
        $captureRoot | Should Exist
        Invoke-WapCli -Command capture -Arguments @('rename', 'kicad', 'electronics-kicad') -RepositoryRoot $repo

        $newCaptureRoot = Join-Path $repo '.capture/electronics-kicad'
        $captureRoot | Should Not Exist
        $newCaptureRoot | Should Exist
        $session = Get-Content -LiteralPath (Join-Path $newCaptureRoot 'session.json') -Raw | ConvertFrom-Json
        $manifest = Get-Content -LiteralPath (Join-Path $newCaptureRoot 'output/capture-manifest.json') -Raw | ConvertFrom-Json
        $session.profileName | Should Be 'electronics-kicad'
        $session.renamedFrom | Should Be 'kicad'
        $manifest.profileName | Should Be 'electronics-kicad'
        $manifest.renamedFrom | Should Be 'kicad'
    }

    It 'attaches, lists, edits, copies, and removes profile captures' {
        $repo = Join-Path $TestDrive 'profile-captures'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        New-Item -ItemType Directory -Path (Join-Path $repo 'profiles/dev'), (Join-Path $repo 'profiles/ops'), (Join-Path $repo '.capture/electronics/output') -Force | Out-Null
        @('name: dev', 'apps:') | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml')
        @('name: ops', 'apps:') | Set-Content -LiteralPath (Join-Path $repo 'profiles/ops/profile.yaml')
        [ordered]@{
            version = 1
            profileName = 'electronics'
            createdAt = '2026-01-01T00:00:00Z'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo '.capture/electronics/session.json') -Encoding UTF8
        [ordered]@{
            version = 1
            profileName = 'electronics'
            capturedAt = '2026-01-01T00:05:00Z'
            safety = [ordered]@{
                destructiveActionsPerformed = $false
                registryDeletionPerformed = $false
                msixGenerated = $false
            }
            addedFiles = @([ordered]@{ scope = 'AppDataLocal'; path = 'C:\Users\WDAGUtilityAccount\AppData\Local\Tool\tool.exe' })
            changedRegistryKeys = @()
            newServices = @()
            newWingetPackages = @([ordered]@{ id = 'KiCad.KiCad'; source = 'winget' })
            newShortcuts = @()
            suspectedUninstallCommands = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $repo '.capture/electronics/output/capture-manifest.json') -Encoding UTF8
        @(
            'name: electronics'
            'apps:'
            '  - id: KiCad.KiCad'
            '    source: winget'
            '    enabled: true'
        ) | Set-Content -LiteralPath (Join-Path $repo '.capture/electronics/output/profile.yaml')

        Invoke-WapCli -Command profile -Arguments @('capture', 'add', 'dev', 'electronics', '--id', 'kicad', '--name', 'KiCad', '--description', 'Electronics tools') -RepositoryRoot $repo
        $metadataPath = Join-Path $repo 'profiles/dev/captures/kicad/metadata.json'
        $manifestPath = Join-Path $repo 'profiles/dev/captures/kicad/capture-manifest.json'
        $metadataPath | Should Exist
        $manifestPath | Should Exist
        $metadataRaw = Get-Content -LiteralPath $metadataPath -Raw
        $metadata = $metadataRaw | ConvertFrom-Json
        $metadata.id | Should Be 'kicad'
        $metadata.name | Should Be 'KiCad'
        $metadata.description | Should Be 'Electronics tools'
        $metadataRaw | Should Match '"createdAt":\s+"2026-01-01T00:00:00Z"'
        $profileYaml = Get-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml') -Raw
        $profileYaml | Should Match 'captures:'
        $profileYaml | Should Match 'id: kicad'
        $profileYaml | Should Match 'enabled: true'
        $profileYaml | Should Not Match 'KiCad\.KiCad'
        $profile = Import-WapProfile -Name dev -RepositoryRoot $repo
        @($profile.apps).Count | Should Be 0
        $captureProfilePath = Join-Path $repo 'profiles/dev/captures/kicad/profile.yaml'
        $captureProfilePath | Should Exist
        $captureProfileYaml = Get-Content -LiteralPath $captureProfilePath -Raw
        $captureProfileYaml | Should Match 'name: kicad'
        $captureProfileYaml | Should Match 'id: KiCad\.KiCad'
        $captureProfileYaml | Should Match 'enabled: true'

        $list = (Invoke-WapCli -Command profile -Arguments @('capture', 'list', 'dev') -RepositoryRoot $repo *>&1 | Out-String)
        $list | Should Match 'kicad'
        $list | Should Match 'KiCad'
        $list | Should Match 'True'

        Invoke-WapCli -Command profile -Arguments @('capture', 'disable', 'dev', 'kicad') -RepositoryRoot $repo
        $list = (Invoke-WapCli -Command profile -Arguments @('capture', 'list', 'dev') -RepositoryRoot $repo *>&1 | Out-String)
        $list | Should Match 'False'
        Invoke-WapCli -Command profile -Arguments @('capture', 'enable', 'dev', 'kicad') -RepositoryRoot $repo

        Invoke-WapCli -Command profile -Arguments @('capture', 'edit', 'dev', 'kicad', '--name', 'KiCad 10', '--description', 'Updated') -RepositoryRoot $repo
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.name | Should Be 'KiCad 10'
        $metadata.description | Should Be 'Updated'
        $metadata.PSObject.Properties['updatedAt'] | Should Not Be $null

        New-Item -ItemType Directory -Path (Join-Path $repo '.capture/electronics-refresh/output') -Force | Out-Null
        [ordered]@{
            version = 1
            profileName = 'electronics-refresh'
            capturedAt = '2026-01-02T00:05:00Z'
            safety = [ordered]@{
                destructiveActionsPerformed = $false
                registryDeletionPerformed = $false
                msixGenerated = $false
            }
            addedFiles = @(
                [ordered]@{ scope = 'AppDataLocal'; path = 'C:\Users\WDAGUtilityAccount\AppData\Local\Tool\tool.exe' },
                [ordered]@{ scope = 'AppDataLocal'; path = 'C:\Users\WDAGUtilityAccount\AppData\Local\Tool\new-version.dll' }
            )
            changedRegistryKeys = @(
                [ordered]@{ change = 'Added'; hive = 'HKCU'; key = 'HKEY_CURRENT_USER\Software\Tool\NewVersion' }
            )
            newServices = @()
            newShortcuts = @()
            suspectedUninstallCommands = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $repo '.capture/electronics-refresh/output/capture-manifest.json') -Encoding UTF8

        Invoke-WapCli -Command profile -Arguments @('capture', 'refresh', 'dev', 'kicad', 'electronics-refresh', '--description', 'Tool update', '--apply') -RepositoryRoot $repo
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.selectedVersion | Should Be 'v0001'
        @($metadata.versions).Count | Should Be 1
        $deltaPath = Join-Path $repo 'profiles/dev/captures/kicad/versions/v0001/capture-delta.json'
        $deltaPath | Should Exist
        $delta = Get-Content -LiteralPath $deltaPath -Raw | ConvertFrom-Json
        @($delta.addedFiles).Count | Should Be 1
        @($delta.changedRegistryKeys).Count | Should Be 1

        $versionsOutput = (Invoke-WapCli -Command profile -Arguments @('capture', 'versions', 'dev', 'kicad') -RepositoryRoot $repo *>&1 | Out-String)
        $versionsOutput | Should Match 'Selected version:\s+v0001'
        $versionsOutput | Should Match 'Tool update'

        Invoke-WapCli -Command profile -Arguments @('capture', 'select-version', 'dev', 'kicad', 'base') -RepositoryRoot $repo
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.selectedVersion | Should Be 'base'
        Invoke-WapCli -Command profile -Arguments @('capture', 'select-version', 'dev', 'kicad', 'latest') -RepositoryRoot $repo
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.selectedVersion | Should Be 'v0001'

        Invoke-WapCli -Command profile -Arguments @('capture', 'merge', 'dev', 'kicad') -RepositoryRoot $repo
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $mergedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $metadata.selectedVersion | Should Be 'base'
        @($metadata.versions).Count | Should Be 0
        @($mergedManifest.addedFiles | Where-Object { $_.path -like '*new-version.dll' }).Count | Should Be 1

        Invoke-WapCli -Command profile -Arguments @('capture', 'copy', 'dev', 'kicad', 'ops', '--id', 'kicad-copy') -RepositoryRoot $repo
        $copyMetadataPath = Join-Path $repo 'profiles/ops/captures/kicad-copy/metadata.json'
        $copyMetadataPath | Should Exist
        $copyMetadata = Get-Content -LiteralPath $copyMetadataPath -Raw | ConvertFrom-Json
        $copyMetadata.id | Should Be 'kicad-copy'
        $copyMetadata.copiedFromProfile | Should Be 'dev'
        $copyMetadata.copiedFromCaptureId | Should Be 'kicad'
        $opsYaml = Get-Content -LiteralPath (Join-Path $repo 'profiles/ops/profile.yaml') -Raw
        $opsYaml | Should Match 'id: kicad-copy'
        $opsYaml | Should Match 'enabled: true'

        Invoke-WapCli -Command profile -Arguments @('capture', 'remove', 'dev', 'kicad', '-WhatIf') -RepositoryRoot $repo
        (Join-Path $repo 'profiles/dev/captures/kicad') | Should Exist
        Invoke-WapCli -Command profile -Arguments @('capture', 'remove', 'dev', 'kicad') -RepositoryRoot $repo
        (Join-Path $repo 'profiles/dev/captures/kicad') | Should Not Exist
        $profileYaml = Get-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml') -Raw
        $profileYaml | Should Not Match '(?m)^\s{2}- id: kicad$'
    }

    It 'adds, lists, shows, and removes winget packages on a profile' {
        $repo = Join-Path $TestDrive 'profile-winget'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        New-Item -ItemType Directory -Path (Join-Path $repo 'profiles/dev'), (Join-Path $repo 'profiles/dev/captures/python') -Force | Out-Null
        @('name: dev', 'env:', '  WAP_PROFILE: dev') | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml')
        [ordered]@{
            id = 'python'
            name = 'Python settings'
            selectedVersion = 'base'
            versions = @()
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/python/metadata.json') -Encoding UTF8

        Invoke-WapCli -Command profile -Arguments @('winget', 'add', 'dev', 'Python.Python.3.13') -RepositoryRoot $repo
        Invoke-WapCli -Command profile -Arguments @('winget', 'add', 'dev', 'Microsoft.VisualStudioCode', '--source', 'msstore') -RepositoryRoot $repo

        $profile = Import-WapProfile -Name dev -RepositoryRoot $repo
        @($profile.apps).Count | Should Be 2
        $profile.apps[0].id | Should Be 'Python.Python.3.13'
        $profile.apps[0].source | Should Be 'winget'
        $profile.apps[0].enabled | Should Be $true
        $profile.apps[1].source | Should Be 'msstore'

        $list = (Invoke-WapCli -Command profile -Arguments @('winget', 'list', 'dev') -RepositoryRoot $repo *>&1 | Out-String)
        $list | Should Match 'Python\.Python\.3\.13'
        $list | Should Match 'msstore'
        $list | Should Match 'True'

        Invoke-WapCli -Command profile -Arguments @('winget', 'disable', 'dev', 'Python.Python.3.13') -RepositoryRoot $repo
        $profile = Import-WapProfile -Name dev -RepositoryRoot $repo
        $profile.apps[0].enabled | Should Be $false
        $list = (Invoke-WapCli -Command profile -Arguments @('winget', 'list', 'dev') -RepositoryRoot $repo *>&1 | Out-String)
        $list | Should Match 'False'
        Invoke-WapCli -Command profile -Arguments @('winget', 'enable', 'dev', 'Python.Python.3.13') -RepositoryRoot $repo

        $show = (Invoke-WapCli -Command profile -Arguments @('show', 'dev') -RepositoryRoot $repo *>&1 | Out-String)
        $show | Should Match 'Winget packages:\s+2'
        $show | Should Match 'Attached captures:\s+0'
        $show | Should Match 'Unreferenced capture folders:\s+1'
        $show | Should Match ([regex]::Escape('.\wap.ps1 profile capture enable dev python'))
        $show | Should Match 'Python settings'

        Invoke-WapCli -Command profile -Arguments @('winget', 'remove', 'dev', 'Microsoft.VisualStudioCode', '--source', 'msstore') -RepositoryRoot $repo
        $profile = Import-WapProfile -Name dev -RepositoryRoot $repo
        @($profile.apps).Count | Should Be 1
        $profile.apps[0].id | Should Be 'Python.Python.3.13'
    }

    It 'references orphan captures and normalizes older profile yaml schema on save' {
        $repo = Join-Path $TestDrive 'profile-reference-orphan'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        New-Item -ItemType Directory -Path (Join-Path $repo 'profiles/dev/captures/orphan') -Force | Out-Null
        @(
            'name: dev'
            'apps:'
            '  - id: Git.Git'
            '    source: winget'
            'env:'
            '  WAP_PROFILE: dev'
        ) | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml')
        [ordered]@{
            id = 'orphan'
            name = 'Orphan capture'
            selectedVersion = 'base'
            versions = @()
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/orphan/metadata.json') -Encoding UTF8
        [ordered]@{
            version = 1
            changedRegistryKeys = @()
            addedFiles = @()
            newWingetPackages = @([ordered]@{ id = 'Python.Python.3.13'; source = 'winget' })
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/orphan/capture-manifest.json') -Encoding UTF8

        $list = (Invoke-WapCli -Command profile -Arguments @('capture', 'list', 'dev') -RepositoryRoot $repo *>&1 | Out-String)
        $list | Should Match 'Unreferenced capture folders'
        $list | Should Match 'orphan'
        $list | Should Match ([regex]::Escape('.\wap.ps1 profile capture enable dev orphan'))

        Invoke-WapCli -Command profile -Arguments @('capture', 'enable', 'dev', 'orphan') -RepositoryRoot $repo
        $profile = Import-WapProfile -Name dev -RepositoryRoot $repo
        $profile.apps[0].enabled | Should Be $true
        (@($profile.apps) | Where-Object { $_.id -eq 'Python.Python.3.13' }).Count | Should Be 0
        $profile.captures[0].id | Should Be 'orphan'
        $profile.captures[0].enabled | Should Be $true
        $captureProfileYaml = Get-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/orphan/profile.yaml') -Raw
        $captureProfileYaml | Should Match 'id: Python\.Python\.3\.13'
        $captureProfileYaml | Should Match 'enabled: true'

        $yaml = Get-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml') -Raw
        $yaml | Should Match 'apps:\s+'
        $yaml | Should Match 'id: Git\.Git'
        $yaml | Should Not Match 'id: Python\.Python\.3\.13'
        $yaml | Should Match 'enabled: true'
        $yaml | Should Match 'captures:'
        $yaml | Should Match 'id: orphan'
        $yaml | Should Match 'enabled: true'

        New-Item -ItemType Directory -Path (Join-Path $repo 'profiles/dev/captures/auto') -Force | Out-Null
        [ordered]@{
            id = 'auto'
            name = 'Auto referenced'
            selectedVersion = 'base'
            versions = @()
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/auto/metadata.json') -Encoding UTF8
        [ordered]@{
            version = 1
            changedRegistryKeys = @()
            addedFiles = @()
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/auto/capture-manifest.json') -Encoding UTF8

        Invoke-WapCli -Command profile -Arguments @('capture', 'enable', 'dev', 'auto') -RepositoryRoot $repo
        $profile = Import-WapProfile -Name dev -RepositoryRoot $repo
        (@($profile.captures) | Where-Object { $_.id -eq 'auto' }).enabled | Should Be $true
    }

    It 'installs winget packages non-interactively before reporting captures' {
        $repo = Join-Path $TestDrive 'profile-winget-install'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        New-Item -ItemType Directory -Path (Join-Path $repo 'profiles/dev/captures/settings') -Force | Out-Null
        @(
            'name: dev'
            'apps:'
            '  - id: Python.Python.3.13'
            '    source: winget'
            '    enabled: true'
            '  - id: Disabled.Tool'
            '    source: winget'
            '    enabled: false'
            'captures:'
            '  - id: settings'
            '    enabled: false'
        ) | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml')
        [ordered]@{
            id = 'settings'
            name = 'Python settings'
            selectedVersion = 'base'
            versions = @()
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/settings/metadata.json') -Encoding UTF8

        $wingetLog = Join-Path $repo 'winget-args.log'
        $fakeWinget = Join-Path $repo 'winget.cmd'
        $env:WAP_TEST_FAKE_WINGET = $fakeWinget
        @(
            '@echo off'
            "echo %*>>`"$wingetLog`""
            'if "%1"=="list" exit /b 1'
            'exit /b 0'
        ) | Set-Content -LiteralPath $fakeWinget -Encoding ASCII
        Mock Get-Command { [pscustomobject]@{ Source = $env:WAP_TEST_FAKE_WINGET } } -ParameterFilter { $Name -eq 'winget' } -ModuleName WindowsAutoProfiles

        $output = (Install-WapProfile -Name dev -RepositoryRoot $repo *>&1 | Out-String)
        $wingetArgs = Get-Content -LiteralPath $wingetLog -Raw
        $wingetArgs | Should Match 'list --id Python\.Python\.3\.13 --exact --accept-source-agreements'
        $wingetArgs | Should Match 'install -e --id Python\.Python\.3\.13 --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity'
        $wingetArgs | Should Not Match 'Disabled\.Tool'
        $output | Should Match 'Packages: 2 declared \(1 enabled\)'
        $output | Should Match '\[install\] Python\.Python\.3\.13'
        $output | Should Match '\[skipped\] Disabled\.Tool'
        $output | Should Match 'Attached captures: 1 declared \(0 enabled\)'
        $output | Should Match '\[skipped\] settings'
        $output.IndexOf('Packages: 2 declared') | Should BeLessThan $output.IndexOf('Attached captures: 1 declared')
    }

    It 'installs winget packages owned by enabled captures without adding them to profile apps' {
        $repo = Join-Path $TestDrive 'profile-capture-winget-install'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        New-Item -ItemType Directory -Path (Join-Path $repo 'profiles/dev/captures/python') -Force | Out-Null
        @(
            'name: dev'
            'apps:'
            'captures:'
            '  - id: python'
            '    enabled: true'
        ) | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml')
        @(
            'name: python'
            'apps:'
            '  - id: Python.Python.3.13'
            '    source: winget'
            '    enabled: true'
        ) | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/python/profile.yaml')
        [ordered]@{
            id = 'python'
            name = 'Python'
            selectedVersion = 'base'
            versions = @()
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/python/metadata.json') -Encoding UTF8
        [ordered]@{
            version = 1
            changedRegistryKeys = @()
            addedFiles = @()
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/captures/python/capture-manifest.json') -Encoding UTF8

        $wingetLog = Join-Path $repo 'winget-args.log'
        $fakeWinget = Join-Path $repo 'winget.cmd'
        $env:WAP_TEST_FAKE_WINGET = $fakeWinget
        @(
            '@echo off'
            "echo %*>>`"$wingetLog`""
            'if "%1"=="list" exit /b 1'
            'exit /b 0'
        ) | Set-Content -LiteralPath $fakeWinget -Encoding ASCII
        Mock Get-Command { [pscustomobject]@{ Source = $env:WAP_TEST_FAKE_WINGET } } -ParameterFilter { $Name -eq 'winget' } -ModuleName WindowsAutoProfiles

        $output = (Install-WapProfile -Name dev -RepositoryRoot $repo *>&1 | Out-String)
        $wingetArgs = Get-Content -LiteralPath $wingetLog -Raw
        $wingetArgs | Should Match 'install -e --id Python\.Python\.3\.13 --source winget'
        $output | Should Match 'Attached captures: 1 declared \(1 enabled\)'
        $output | Should Match 'Packages: 1 declared \(1 enabled\)'
        $output | Should Match '\[installed\] Python\.Python\.3\.13'
        $profileYaml = Get-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml') -Raw
        $profileYaml | Should Not Match 'Python\.Python\.3\.13'
    }

    It 'fails a stuck winget install with a package timeout' {
        $repo = Join-Path $TestDrive 'profile-winget-timeout'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        New-Item -ItemType Directory -Path (Join-Path $repo 'profiles/dev') -Force | Out-Null
        @(
            'name: dev'
            'apps:'
            '  - id: Slow.Package'
            '    source: winget'
            '    enabled: true'
        ) | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml')

        $fakeWinget = Join-Path $repo 'winget.cmd'
        $env:WAP_TEST_FAKE_WINGET = $fakeWinget
        @(
            '@echo off'
            'if "%1"=="list" exit /b 1'
            'ping -n 6 127.0.0.1 >nul'
            'exit /b 0'
        ) | Set-Content -LiteralPath $fakeWinget -Encoding ASCII
        Mock Get-Command { [pscustomobject]@{ Source = $env:WAP_TEST_FAKE_WINGET } } -ParameterFilter { $Name -eq 'winget' } -ModuleName WindowsAutoProfiles

        $oldTimeout = $env:WAP_WINGET_INSTALL_TIMEOUT_SECONDS
        $message = $null
        try {
            $env:WAP_WINGET_INSTALL_TIMEOUT_SECONDS = '1'
            Install-WapProfile -Name dev -RepositoryRoot $repo
        }
        catch {
            $message = $_.Exception.Message
        }
        finally {
            $env:WAP_WINGET_INSTALL_TIMEOUT_SECONDS = $oldTimeout
        }

        $message | Should Match "winget timed out installing 'Slow\.Package'"
    }

    It 'launches a sandbox profile install test with mounted scripts and profiles' {
        $repo = Join-Path $TestDrive 'profile-install-sandbox'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        New-Item -ItemType Directory -Path (Join-Path $repo 'profiles/dev') -Force | Out-Null
        @(
            'name: dev'
            'apps:'
            '  - id: Python.Python.3.13'
            '    source: winget'
        ) | Set-Content -LiteralPath (Join-Path $repo 'profiles/dev/profile.yaml')
        Mock Save-WapSandboxWingetPrerequisites {} -ModuleName WindowsAutoProfiles
        Mock Get-Command { [pscustomobject]@{ Source = 'WindowsSandbox.exe' } } `
            -ParameterFilter { $Name -eq 'WindowsSandbox.exe' } -ModuleName WindowsAutoProfiles
        Mock Start-Process {
            $wsbPath = if ($ArgumentList -is [array]) { $ArgumentList[0] } else { $ArgumentList }
            $sessionRoot = Split-Path -Parent $wsbPath
            $outputRoot = Join-Path $sessionRoot 'output'
            New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
            [ordered]@{
                phase = 'completed'
                success = $true
                updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                error = $null
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'status.json') -Encoding UTF8
            [ordered]@{
                phase = 'installingProfile'
                success = $false
                updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                stepType = 'package'
                stepState = 'skipped'
                item = 'Disabled.Tool'
                index = 2
                total = 2
                detail = 'package 2/2 skipped: Disabled.Tool'
                error = $null
            } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $outputRoot 'status-events.jsonl') -Encoding UTF8
            $process = New-Object psobject -Property @{ HasExited = $false }
            $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
            return $process
        } -ModuleName WindowsAutoProfiles

        $output = (Invoke-WapCli -Command profile -Arguments @('install', 'dev', '--sandbox') -RepositoryRoot $repo *>&1 | Out-String)

        $sessionRoot = Join-Path $repo '.sandbox/profile-install/dev'
        (Join-Path $sessionRoot 'Profile-Install-Startup.ps1') | Should Exist
        (Join-Path $sessionRoot 'sandbox.wsb') | Should Exist
        $startup = Get-Content -LiteralPath (Join-Path $sessionRoot 'Profile-Install-Startup.ps1') -Raw
        $startup | Should Match 'wap.ps1 init'
        $startup | Should Match 'WAP_WINGET_PREREQ_ROOT'
        $startup | Should Match 'profile install'
        $startup | Should Match 'WAP_PROFILE_INSTALL_STATUS_PATH'
        $startup | Should Match 'WAP_PROFILE_INSTALL_EVENTS_PATH'
        $startup | Should Match 'Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force'
        $startup | Should Match 'profile activate <profile>'
        $startup | Should Match 'profile deactivate <profile>'
        $startup | Should Match 'profile uninstall <profile>'
        $startup | Should Match 'profile-testing\.md'
        $startup | Should Match 'C:\\WAPProfiles'
        $startup | Should Match "'wap.ps1', 'src', 'templates', 'docs', 'README.md'"
        $startup | Should Not Match "Copy-Item -Path 'C:\\WAPRepo\\\*'"
        $startup | Should Match 'if \(-not \$\?\)'
        $startup | Should Not Match 'LASTEXITCODE -ne 0'
        $startup.IndexOf("Set-Content -LiteralPath (Join-Path `$sandboxRepo 'wap.config.json')") | Should BeLessThan $startup.IndexOf('& .\wap.ps1 init')
        $wsb = Get-Content -LiteralPath (Join-Path $sessionRoot 'sandbox.wsb') -Raw
        $wsb | Should Match ([regex]::Escape('<SandboxFolder>C:\WAPProfileSandbox</SandboxFolder>'))
        $wsb | Should Match ([regex]::Escape('<SandboxFolder>C:\WAPRepo</SandboxFolder>'))
        $wsb | Should Match ([regex]::Escape('<SandboxFolder>C:\WAPProfiles</SandboxFolder>'))
        $wsb | Should Match '-NoExit'
        $output | Should Match 'Sandbox launched'
        $output | Should Match 'Sandbox profile install step: package 2/2 skipped: Disabled\.Tool'
        $output | Should Match 'SANDBOX PROFILE INSTALL COMPLETE'
        $output | Should Match 'Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force'
        $output | Should Match 'manual profile lifecycle testing'
        $output | Should Match 'C:\\WAPProfileSandbox\\profile-testing\.md'
        Assert-MockCalled Save-WapSandboxWingetPrerequisites 1 -ModuleName WindowsAutoProfiles -Scope It
        Assert-MockCalled Start-Process 1 -ModuleName WindowsAutoProfiles -Scope It
    }
}

Describe 'profile deletion' {
    It 'supports WhatIf and deletes only an uninstalled profile definition' {
        $repo = Join-Path $TestDrive 'delete-profile'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        $profilePath = Join-Path $repo 'profiles/disposable'
        New-Item -ItemType Directory -Path $profilePath | Out-Null
        @('name: disposable', 'apps:') | Set-Content -LiteralPath (Join-Path $profilePath 'profile.yaml')

        Invoke-WapCli -Command profile -Arguments @('delete', 'disposable', '-WhatIf') -RepositoryRoot $repo
        $profilePath | Should Exist
        Invoke-WapCli -Command profile -Arguments @('delete', 'disposable') -RepositoryRoot $repo
        $profilePath | Should Not Exist
    }

    It 'refuses to delete an installed profile definition' {
        $repo = Join-Path $TestDrive 'delete-installed-profile'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        $profilePath = Join-Path $repo 'profiles/installed'
        New-Item -ItemType Directory -Path $profilePath | Out-Null
        @('name: installed', 'apps:') | Set-Content -LiteralPath (Join-Path $profilePath 'profile.yaml')
        $state = Get-WapState -RepositoryRoot $repo
        $state.profiles.installed = [ordered]@{ installed = $true; activation = $null }
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $repo '.wap-state.json')

        $message = $null
        try { Remove-WapProfileDefinition -Name installed -RepositoryRoot $repo }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'Uninstall it before deleting'
        $profilePath | Should Exist
    }
}
Describe 'profile uninstall' {
    It 'automatically deactivates an active profile before uninstalling it' {
        $repo = Join-Path $TestDrive 'uninstall-active-profile'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo -SkipPrereqs
        $state = Get-WapState -RepositoryRoot $repo
        $state.activeProfile = 'active'
        $state.profiles.active = [ordered]@{
            installed = $true
            profileRoot = Join-Path $TestDrive 'active-workspace'
            packages = @()
            installedPackages = @()
            shortcuts = @()
            activation = [ordered]@{
                environment = [ordered]@{}
                pathAdded = @()
                activatedAt = '2026-01-01T00:00:00Z'
            }
        }
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $repo '.wap-state.json')

        $output = (Invoke-WapCli -Command profile -Arguments @('uninstall', 'active') -RepositoryRoot $repo *>&1 | Out-String)
        $state = Get-WapState -RepositoryRoot $repo

        $output | Should Match 'Profile is active; deactivating it first'
        $state.activeProfile | Should Be $null
        $state.profiles.Contains('active') | Should Be $false
    }

    It 'cleans profile user data and added HKCU registry keys on explicit request' {
        $repo = Join-Path $TestDrive 'profile-cleanup'
        $workspace = Join-Path $TestDrive 'cleanup-workspaces'
        $profileDirectory = Join-Path $repo 'profiles/cleanup'
        $captureDirectory = Join-Path $profileDirectory 'captures/test'
        $profileRoot = Join-Path $workspace 'cleanup'
        $registryKey = "HKEY_CURRENT_USER\Software\WindowsAutoProfilesTests\$([guid]::NewGuid().ToString('N'))"
        $providerPath = "Registry::$registryKey"
        New-Item -ItemType Directory -Path $profileDirectory, $captureDirectory, $profileRoot -Force | Out-Null
        Write-TestConfig -RepositoryRoot $repo -WorkspaceRoot $workspace
        @"
name: cleanup
apps:
env:
path:
projects: `${profileRoot}\Projects
data: `${profileRoot}\Data
downloads: `${profileRoot}\Downloads
cache: `${profileRoot}\Cache
"@ | Set-Content -LiteralPath (Join-Path $profileDirectory 'profile.yaml')
        [ordered]@{
            version = 1
            changedRegistryKeys = @(
                [ordered]@{ hive = 'HKCU'; key = $registryKey; change = 'Added' }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $captureDirectory 'capture-manifest.json') -Encoding UTF8
        New-Item -Path $providerPath -Force | Out-Null

        try {
            Invoke-WapCli -Command profile -Arguments @('cleanup', 'cleanup', '--user-data', '--registry') -RepositoryRoot $repo

            $profileRoot | Should Not Exist
            (Test-Path -LiteralPath $providerPath) | Should Be $false
        }
        finally {
            if (Test-Path -LiteralPath $providerPath) {
                Remove-Item -LiteralPath $providerPath -Recurse -Force
            }
        }
    }
}
Describe 'installation preview' {
    It 'uses derived paths and does not create profile state under WhatIf' {
        $repo = Join-Path $TestDrive 'preview'
        $workspace = Join-Path $TestDrive 'preview-workspaces'
        New-Item -ItemType Directory -Path (Join-Path $repo 'profiles/empty') -Force | Out-Null
        Write-TestConfig -RepositoryRoot $repo -WorkspaceRoot $workspace
        @"
name: empty
apps:
env:
path:
projects: `${profileRoot}\Projects
data: `${profileRoot}\Data
downloads: `${profileRoot}\Downloads
cache: `${profileRoot}\Cache
"@ | Set-Content -LiteralPath (Join-Path $repo 'profiles/empty/profile.yaml')
        Install-WapProfile -Name empty -RepositoryRoot $repo -WhatIf
        (Join-Path $repo '.wap-state.json') | Should Not Exist
        (Join-Path $workspace 'empty') | Should Not Exist
    }
}
