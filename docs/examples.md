# WindowsAutoProfiles examples

Version: 1.1

Last updated: 2026-07-04T06:56:18Z

Author: Michal Zygmunt <lahcim@fajne.com>

Minimum PowerShell: 5.1

This file is printed by:

```powershell
.\wap.ps1 --examples
```

## Scenario 1: First-time setup

1. Initialize repository-local configuration and state.

   Command:

   ```powershell
   .\wap.ps1 init
   ```

   `init` also installs prerequisites such as winget when missing. To skip
   prerequisite installation:

   ```powershell
   .\wap.ps1 init --skip-prereqs
   ```

   Example output:

   ```text
   WindowsAutoProfiles initialized at 'C:\src\WindowsAutoProfiles'.
   Log file: C:\src\WindowsAutoProfiles\.logs\20260704T025138Z-init-7f3a.log
   ```

2. Optionally move the full settings file and profile definitions to OneDrive.

   Commands:

   ```powershell
   .\wap.ps1 config set bootstrapConfigPath '%OneDrive%\WindowsAutoProfiles\wap.bootstrap.json'
   .\wap.ps1 config set configPath '%OneDrive%\WindowsAutoProfiles\wap.settings.json'
   .\wap.ps1 config set profilesRoot '%OneDrive%\WindowsAutoProfiles\profiles'
   .\wap.ps1 config set logging.root '%LOCALAPPDATA%\WindowsAutoProfiles\Logs'
   ```

   Example output:

   ```text
   bootstrapConfigPath set to '%OneDrive%\WindowsAutoProfiles\wap.bootstrap.json'.
   Resolved bootstrap config path: C:\Users\me\OneDrive\WindowsAutoProfiles\wap.bootstrap.json
   configPath set to '%OneDrive%\WindowsAutoProfiles\wap.settings.json'.
   Resolved config path: C:\Users\me\OneDrive\WindowsAutoProfiles\wap.settings.json
   profilesRoot set to '%OneDrive%\WindowsAutoProfiles\profiles'.
   Resolved profiles root: C:\Users\me\OneDrive\WindowsAutoProfiles\profiles
   logging.root set to '%LOCALAPPDATA%\WindowsAutoProfiles\Logs'.
   Resolved logging root: C:\Users\me\AppData\Local\WindowsAutoProfiles\Logs
   WARNING: Logging root does not exist yet. It will be created when logging starts on the next command.
   ```

3. Set the workspace root where installed profile workspace folders will be created.

   Command:

   ```powershell
   .\wap.ps1 config set workspaceRoot '%USERPROFILE%\Workspaces'
   ```

   Example output:

   ```text
   workspaceRoot set to '%USERPROFILE%\Workspaces'.
   Resolved workspace root: C:\Users\me\Workspaces
   Log file: C:\Users\me\AppData\Local\WindowsAutoProfiles\Logs\20260704T025141Z-config-set-workspaceroot-9c1b.log
   ```

4. Review the effective configuration.

   Command:

   ```powershell
   .\wap.ps1 config show
   ```

   Example output:

   ```text
   Configurable settings (use ".\wap.ps1 config set <key> <value>" on these keys only):

   version               : 1
   bootstrapConfigPath   : %OneDrive%\WindowsAutoProfiles\wap.bootstrap.json
   configPath            : %OneDrive%\WindowsAutoProfiles\wap.settings.json
   workspaceRoot         : %USERPROFILE%\Workspaces
   profilesRoot          : %OneDrive%\WindowsAutoProfiles\profiles
   logging.enabled       : True
   logging.retentionDays : 30
   logging.root          : %LOCALAPPDATA%\WindowsAutoProfiles\Logs
   sandbox.installWinget : True

   Dynamic resolved settings (read-only; computed at runtime from the configurable settings above):

   local.bootstrapConfigPath    : C:\src\WindowsAutoProfiles\wap.config.json
   resolved.bootstrapConfigPath : C:\Users\me\OneDrive\WindowsAutoProfiles\wap.bootstrap.json
   resolved.configPath          : C:\Users\me\OneDrive\WindowsAutoProfiles\wap.settings.json
   resolved.workspaceRoot       : C:\Users\me\Workspaces
   resolved.profilesRoot        : C:\Users\me\OneDrive\WindowsAutoProfiles\profiles
   resolved.logging.root        : C:\Users\me\AppData\Local\WindowsAutoProfiles\Logs
   ```

## Scenario 2: Create, install, and activate a profile

1. Create an empty placeholder profile and edit it.

   Commands:

   ```powershell
   .\wap.ps1 profile new electronics
   notepad <profilesRoot>\electronics\profile.yaml
   ```

   Example output:

   ```text
   Created profile 'electronics' at 'C:\Users\me\OneDrive\WindowsAutoProfiles\profiles\electronics\profile.yaml'.
   Edit it, then install it with:
     .\wap.ps1 profile install electronics
   ```

2. Preview the work before changing the machine.

   Command:

   ```powershell
   .\wap.ps1 profile install electronics -WhatIf
   ```

   Example output:

   ```text
   Installing profile 'electronics'...
     Profile root: C:\Workspaces\electronics
     Packages: 1 declared
       [install] KiCad.KiCad
   What if: Performing the operation "Create directory" on target "C:\Workspaces\electronics".
   ```

3. Install the profile for real.

   Command:

   ```powershell
   .\wap.ps1 profile install electronics
   ```

   Example output:

   ```text
   Installing profile 'electronics'...
     Profile root: C:\Workspaces\electronics
     Packages: 1 declared
       [install] KiCad.KiCad
   Done: profile 'electronics' installed.
   Profile 'electronics' is installed but not active. Activate it with:
     .\wap.ps1 profile activate electronics
   ```

4. Activate user-level environment variables and PATH entries.

   Command:

   ```powershell
   .\wap.ps1 profile activate electronics
   ```

   Example output:

   ```text
   Activating profile 'electronics'...
     [env] WAP_PROFILE=electronics
     [path] C:\Workspaces\electronics\Apps\bin
   Done: profile 'electronics' activated.
   ```

## Scenario 3: Capture an interactive installer and attach it to a profile

1. Start a standalone Windows Sandbox capture.

   Command:

   ```powershell
   .\wap.ps1 capture start kicad
   ```

   Example output:

   ```text
   Creating capture session 'kicad'...
     Capture root: C:\src\WindowsAutoProfiles\.capture\kicad
     Sandbox winget bootstrap: enabled
     Sandbox: C:\src\WindowsAutoProfiles\.capture\kicad\WindowsAutoProfiles.wsb
   Launching Windows Sandbox...
   ```

2. Inside the Sandbox, install the application and finalize the capture.

   Command inside Sandbox:

   ```powershell
   C:\WAPCapture\Capture-Finalize.ps1
   ```

   Example output:

   ```text
   Capture finalized to C:\WAPCapture\out\capture-manifest.json
   ```

3. Validate and attach the capture to a profile.

   Commands:

   ```powershell
   .\wap.ps1 capture validate kicad
   .\wap.ps1 profile capture add electronics kicad --id kicad --name "KiCad" --description "KiCad interactive installer evidence"
   ```

   Example output:

   ```text
   Capture 'kicad' is valid.
   Added capture 'kicad' to profile 'electronics'.
   ```

## Scenario 4: Refresh an attached capture after an application updates

1. Capture the updated application state as a new standalone capture.

   Command:

   ```powershell
   .\wap.ps1 capture start kicad-refresh
   ```

2. Create a diff-only version and select it for future installs.

   Command:

   ```powershell
   .\wap.ps1 profile capture refresh electronics kicad kicad-refresh --description "KiCad monthly update" --apply
   ```

   Example output:

   ```text
   Added refresh version 'v0001' to capture 'kicad' on profile 'electronics'.
   Selected version is now 'v0001'.
     addedFiles: 3
     changedRegistryKeys: 2
   ```

3. List versions and roll back if needed.

   Commands:

   ```powershell
   .\wap.ps1 profile capture versions electronics kicad
   .\wap.ps1 profile capture select-version electronics kicad base
   ```

   Example output:

   ```text
   Capture 'kicad' versions for profile 'electronics':
     base
     v0001  selected  KiCad monthly update
   Selected version 'base' for capture 'kicad' on profile 'electronics'.
   ```

4. Merge known-good patch versions into the base capture.

   Command:

   ```powershell
   .\wap.ps1 profile capture merge electronics kicad --up-to v0001
   ```

   Example output:

   ```text
   Merged capture 'kicad' through version 'v0001'.
   Backup: C:\src\WindowsAutoProfiles\profiles\electronics\captures\kicad\capture-manifest.before-merge-20260704T025138Z.json
   ```

## Scenario 5: Deactivate, uninstall, and optional destructive cleanup

1. Deactivate the active profile without uninstalling packages.

   Command:

   ```powershell
   .\wap.ps1 profile deactivate electronics
   ```

   Example output:

   ```text
   Deactivating profile 'electronics'...
     [env remove] WAP_PROFILE
     [path remove] C:\Workspaces\electronics\Apps\bin
   Done: profile 'electronics' deactivated.
   ```

2. Uninstall the profile while preserving workspace data and registry evidence.

   Command:

   ```powershell
   .\wap.ps1 profile uninstall electronics
   ```

   Example output:

   ```text
   Uninstalling profile 'electronics'...
     Packages: 1 installed by this profile
       [remove] KiCad.KiCad
     [keep] Workspace directories and user data under 'C:\Workspaces\electronics'.
     [dry-run] Registry cleanup is disabled; no registry keys were deleted.
   Done: profile 'electronics' uninstalled.
   ```

3. Opt in to full cleanup only when you are sure.

   Command:

   ```powershell
   .\wap.ps1 profile cleanup electronics --all
   ```

   Example output:

   ```text
   Cleaning profile 'electronics'...
     Registry cleanup: 4 added capture keys eligible
     [delete] User data directory 'C:\Workspaces\electronics'
   Done: profile 'electronics' cleanup completed.
   ```

## Scenario 6: Troubleshooting logs

1. Run any command normally; a detailed log is generated automatically.

   Command:

   ```powershell
   .\wap.ps1 profile status
   ```

   Example output:

   ```text
   Available profiles:
     electronics  installed  inactive
   Log file: C:\Users\me\AppData\Local\WindowsAutoProfiles\Logs\20260704T025152Z-profile-status-4d2e.log
   ```

2. Disable logging for one command, or change retention globally.

   Commands:

   ```powershell
   .\wap.ps1 profile status --no-log
   .\wap.ps1 config set logging.retentionDays 14
   .\wap.ps1 logs cleanup
   ```

   Example output:

   ```text
   logging.retentionDays set to '14'.
   Deleting 3 generated log file(s) from 'C:\Users\me\AppData\Local\WindowsAutoProfiles\Logs'.
   ```
