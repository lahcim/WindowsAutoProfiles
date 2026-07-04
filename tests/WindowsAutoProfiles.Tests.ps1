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
    It 'initializes config and state idempotently without overwriting config' {
        $repo = Join-Path $TestDrive 'init'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo
        $customRoot = Join-Path $TestDrive 'custom-workspaces'
        Write-TestConfig -RepositoryRoot $repo -WorkspaceRoot $customRoot
        Initialize-Wap -RepositoryRoot $repo
        $state = Get-WapState -RepositoryRoot $repo
        $config = Get-WapConfig -RepositoryRoot $repo
        $state.version | Should Be 1
        $state.profiles.Count | Should Be 0
        $state.registry.enabled | Should Be $false
        $config.workspaceRoot | Should Be $customRoot
    }

    It 'shows and sets workspaceRoot through the CLI' {
        $repo = Join-Path $TestDrive 'config-cli'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo
        $newRoot = Join-Path $TestDrive 'configured-workspaces'

        Invoke-WapCli -Command config -Arguments @('set', 'workspaceRoot', $newRoot) -RepositoryRoot $repo
        $config = Get-WapConfig -RepositoryRoot $repo
        $shown = Show-WapConfig -RepositoryRoot $repo | Out-String

        $config.workspaceRoot | Should Be $newRoot
        $shown | Should Match ([regex]::Escape($newRoot))
    }

    It 'shows and sets logging configuration through the CLI' {
        $repo = Join-Path $TestDrive 'logging-config-cli'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo

        Invoke-WapCli -Command config -Arguments @('set', 'logging.enabled', 'false') -RepositoryRoot $repo
        Invoke-WapCli -Command config -Arguments @('set', 'logging.retentionDays', '0') -RepositoryRoot $repo
        $config = Get-WapConfig -RepositoryRoot $repo
        $shown = Show-WapConfig -RepositoryRoot $repo | Out-String

        $config.loggingEnabled | Should Be $false
        $config.loggingRetentionDays | Should Be 0
        $shown | Should Match 'LoggingEnabled\s+:\s+False'
        $shown | Should Match 'LoggingRetentionDays\s+:\s+0'
    }

    It 'cleans generated logs while keeping the current command log' {
        $repo = Join-Path $TestDrive 'logs-cleanup'
        New-Item -ItemType Directory -Path (Join-Path $repo '.logs') -Force | Out-Null
        Initialize-Wap -RepositoryRoot $repo
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
        Initialize-Wap -RepositoryRoot $repo
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
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' } -ModuleName WindowsAutoProfiles
        New-WapCapture -Name fresh -RepositoryRoot $repo
        $path = Join-Path $repo 'profiles/fresh/profile.yaml'
        $path | Should Exist
        $yaml = Get-Content $path -Raw
        $yaml | Should Match 'name: fresh'
        $yaml | Should Match '\$\{profileRoot\}\\Apps\\bin'
        $yaml | Should Not Match '^[A-Za-z]:\\'
    }
}

Describe 'profile status' {
    It 'shows available, inactive, and active profiles through status and list' {
        $repo = Join-Path $TestDrive 'status'
        $workspace = Join-Path $TestDrive 'status-workspaces'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo
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
            $process = New-Object psobject -Property @{ HasExited = $false }
            $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
            return $process
        } -ModuleName WindowsAutoProfiles

        $output = (Start-WapInteractiveCapture -Name demo -RepositoryRoot $repo *>&1 | Out-String)

        $captureRoot = Join-Path $repo '.capture/demo'
        foreach ($item in @(
            'baseline', 'after', 'output', 'sandbox.wsb', 'Capture-Baseline.ps1',
            'Capture-Finalize.ps1', 'Capture-Common.ps1', 'capture-filters.json', 'session.json'
        )) {
            (Join-Path $captureRoot $item) | Should Exist
        }
        $wsb = Get-Content -LiteralPath (Join-Path $captureRoot 'sandbox.wsb') -Raw
        $wsb | Should Match ([regex]::Escape($captureRoot))
        $wsb | Should Match ([regex]::Escape('<SandboxFolder>C:\WAPCapture</SandboxFolder>'))
        $wsb | Should Match ([regex]::Escape('<ReadOnly>false</ReadOnly>'))
        $wsb | Should Match 'Capture-Baseline.ps1'
        (Get-Content (Join-Path $captureRoot 'Capture-Baseline.ps1') -Raw) | Should Match 'Write-CaptureSnapshot'
        (Get-Content (Join-Path $captureRoot 'Capture-Baseline.ps1') -Raw) | Should Match 'BASELINE READY'
        (Get-Content (Join-Path $captureRoot 'Capture-Baseline.ps1') -Raw) | Should Match 'baseline-status.json'
        (Get-Content (Join-Path $captureRoot 'Capture-Common.ps1') -Raw) | Should Match 'Get-Service fallback'
        (Get-Content (Join-Path $captureRoot 'Capture-Common.ps1') -Raw) | Should Match 'Get-CaptureCurrentUser'
        (Get-Content (Join-Path $captureRoot 'Capture-Finalize.ps1') -Raw) | Should Match 'capture-manifest.json'
        (Get-Content (Join-Path $captureRoot 'Capture-Finalize.ps1') -Raw) | Should Match 'captureContext'
        $output | Should Match 'BASELINE READY'
        $output | Should Match 'WDAGUtilityAccount'
        Assert-MockCalled Start-Process 1 -ModuleName WindowsAutoProfiles
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
            newShortcuts = @([ordered]@{ scope = 'CommonStartMenu'; path = 'C:\Start Menu\Demo.lnk' })
            suspectedUninstallCommands = @([ordered]@{ source = 'registry'; command = 'uninstall.exe' })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'capture-manifest.json')

        $diff = (Invoke-WapCli -Command capture -Arguments @('diff', 'demo') -RepositoryRoot $repo *>&1 | Out-String)
        $validate = (Invoke-WapCli -Command capture -Arguments @('validate', 'demo') -RepositoryRoot $repo *>&1 | Out-String)

        $diff | Should Match 'Added files:\s+1'
        $diff | Should Match 'Changed registry keys:\s+1'
        $diff | Should Match 'New services:\s+1'
        $diff | Should Match 'New shortcuts:\s+1'
        $diff | Should Match 'Suspected uninstall commands:\s+1'
        $diff | Should Match 'nothing was deleted and no MSIX was generated'
        $validate | Should Match 'manifest validated'
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
            newShortcuts = @()
            suspectedUninstallCommands = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $repo '.capture/electronics/output/capture-manifest.json') -Encoding UTF8

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

        $list = (Invoke-WapCli -Command profile -Arguments @('capture', 'list', 'dev') -RepositoryRoot $repo *>&1 | Out-String)
        $list | Should Match 'kicad'
        $list | Should Match 'KiCad'

        Invoke-WapCli -Command profile -Arguments @('capture', 'edit', 'dev', 'kicad', '--name', 'KiCad 10', '--description', 'Updated') -RepositoryRoot $repo
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.name | Should Be 'KiCad 10'
        $metadata.description | Should Be 'Updated'
        $metadata.PSObject.Properties['updatedAt'] | Should Not Be $null

        Invoke-WapCli -Command profile -Arguments @('capture', 'copy', 'dev', 'kicad', 'ops', '--id', 'kicad-copy') -RepositoryRoot $repo
        $copyMetadataPath = Join-Path $repo 'profiles/ops/captures/kicad-copy/metadata.json'
        $copyMetadataPath | Should Exist
        $copyMetadata = Get-Content -LiteralPath $copyMetadataPath -Raw | ConvertFrom-Json
        $copyMetadata.id | Should Be 'kicad-copy'
        $copyMetadata.copiedFromProfile | Should Be 'dev'
        $copyMetadata.copiedFromCaptureId | Should Be 'kicad'

        Invoke-WapCli -Command profile -Arguments @('capture', 'remove', 'dev', 'kicad', '-WhatIf') -RepositoryRoot $repo
        (Join-Path $repo 'profiles/dev/captures/kicad') | Should Exist
        Invoke-WapCli -Command profile -Arguments @('capture', 'remove', 'dev', 'kicad') -RepositoryRoot $repo
        (Join-Path $repo 'profiles/dev/captures/kicad') | Should Not Exist
        (Join-Path $repo 'profiles/ops/captures/kicad-copy') | Should Exist
    }
}

Describe 'profile deletion' {
    It 'supports WhatIf and deletes only an uninstalled profile definition' {
        $repo = Join-Path $TestDrive 'delete-profile'
        New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-Wap -RepositoryRoot $repo
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
        Initialize-Wap -RepositoryRoot $repo
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
        Initialize-Wap -RepositoryRoot $repo
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
