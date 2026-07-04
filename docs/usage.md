# Usage and command reference

This document describes the WindowsAutoProfiles command line, profile schema,
and expected command output.

Version: 1.1

Last updated: 2026-07-04T08:38:26Z

Author: Michal Zygmunt <lahcim@fajne.com>

Run all commands from the repository root:

```powershell
Set-Location C:\src\WindowsAutoProfiles
```

If WAP is installed from the MSI, the installer adds the per-user install
folder to `PATH`, so you can run `wap` from any new terminal:

```powershell
wap install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
```

The MSI installs under `%LOCALAPPDATA%\WindowsAutoProfiles`, includes
`wap.cmd`, and initializes `wap.config.json`, `wap.settings.json`,
`.wap-state.json`, `profiles\`, and `.logs\` in that same folder on first run.
Default profile workspaces are created under `%USERPROFILE%\Workspaces`. The ZIP
package includes `wap.cmd` but does not add anything to `PATH`.

## Command overview

Minimum PowerShell for all commands is **5.1**. The CLI validates this before
dispatching each command.

```text
.\wap.ps1 init [--skip-prereqs] [-WhatIf]
.\wap.ps1 --help
.\wap.ps1 --examples
.\wap.ps1 install <github-profile-url> [-WhatIf]
.\wap.ps1 config show
.\wap.ps1 config set bootstrapConfigPath <path> [-WhatIf]
.\wap.ps1 config set configPath <path> [-WhatIf]
.\wap.ps1 config set workspaceRoot <path> [-WhatIf]
.\wap.ps1 config set profilesRoot <path> [-WhatIf]
.\wap.ps1 config set logging.enabled <true|false> [-WhatIf]
.\wap.ps1 config set logging.retentionDays <days> [-WhatIf]
.\wap.ps1 config set logging.root <path> [-WhatIf]
.\wap.ps1 config set sandbox.installWinget <true|false> [-WhatIf]
.\wap.ps1 logs cleanup [-WhatIf]

.\wap.ps1 profile install <name> [--sandbox] [-WhatIf]
.\wap.ps1 profile uninstall <name> [--remove-user-data] [--remove-registry] [-WhatIf]
.\wap.ps1 profile cleanup <name> [--user-data] [--registry] [--all] [-WhatIf]
.\wap.ps1 profile new <name> [-WhatIf]
.\wap.ps1 profile download <name> <github-profile-url> [--force] [-WhatIf]
.\wap.ps1 profile activate <name> [-WhatIf]
.\wap.ps1 profile deactivate <name> [-WhatIf]
.\wap.ps1 profile delete <name> [-WhatIf]
.\wap.ps1 profile remove <name> --Confirm [-WhatIf]
.\wap.ps1 profile status
.\wap.ps1 profile list
.\wap.ps1 profile show <name>

.\wap.ps1 profile winget add <profile> <packageId> [--source <source>] [--version <version>]
.\wap.ps1 profile winget list <profile>
.\wap.ps1 profile winget enable <profile> <packageId> [--source <source>]
.\wap.ps1 profile winget disable <profile> <packageId> [--source <source>]
.\wap.ps1 profile winget remove <profile> <packageId> [--source <source>] [-WhatIf]

.\wap.ps1 profile capture add <profile> <capture> [--id <id>] [--name <name>] [--description <text>]
.\wap.ps1 profile capture list <profile>
.\wap.ps1 profile capture enable <profile> <captureId>
.\wap.ps1 profile capture disable <profile> <captureId>
.\wap.ps1 profile capture remove <profile> <captureId> [-WhatIf]
.\wap.ps1 profile capture copy <fromProfile> <captureId> <toProfile> [--id <id>] [--name <name>] [--description <text>]
.\wap.ps1 profile capture edit <profile> <captureId> [--name <name>] [--description <text>]
.\wap.ps1 profile capture refresh <profile> <captureId> <capture> [--description <text>] [--apply]
.\wap.ps1 profile capture versions <profile> <captureId>
.\wap.ps1 profile capture select-version <profile> <captureId> <base|latest|version>
.\wap.ps1 profile capture merge <profile> <captureId> [--up-to <version>]

.\wap.ps1 capture new <name>
.\wap.ps1 capture start <name> [--no-winget] [-WhatIf]
.\wap.ps1 capture list
.\wap.ps1 capture rename <name> <newName> [-WhatIf]
.\wap.ps1 capture validate <name>
.\wap.ps1 capture diff <name>
.\wap.ps1 capture applyfilter <name>
.\wap.ps1 capture remove <name> --Confirm [-WhatIf]
```

All commands accept the global `--no-log` option to skip log generation for
that invocation:

```powershell
.\wap.ps1 profile status --no-log
```

Use `--examples` to print step-by-step populated scenarios from
`docs\examples.md`:

```powershell
.\wap.ps1 --examples
```

## Quick install from GitHub

### 1. One-time direct install

```powershell
.\wap.ps1 install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
```

WAP downloads the branch archive to a temporary folder, runs
`profile install <name>` and `profile activate <name>` from that temporary
profile definition, then removes the temporary files when the command finishes.
It does not save the profile definition locally.

### 2. Download first, then install locally

```powershell
.\wap.ps1 profile download electronics https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
.\wap.ps1 profile install electronics
.\wap.ps1 profile activate electronics
```

This copies the remote profile folder under the configured `profilesRoot` using
the local name `electronics`, and rewrites `profile.yaml` to match that local
profile name. Add `--force` to overwrite an existing downloaded profile
definition with the same local name. This may be required when refreshing a
profile you downloaded before.

Use GitHub folder URLs in this format:

```text
https://github.com/<owner>/<repo>/tree/<branch>/<path-to-profile-folder>
```

The small bootstrap file `wap.config.json` points at the full settings file.
By default it points to `wap.settings.json` beside the script, but it can be
moved to OneDrive or another location:

```powershell
.\wap.ps1 config set configPath '%OneDrive%\WindowsAutoProfiles\wap.settings.json'
.\wap.ps1 config set profilesRoot '%OneDrive%\WindowsAutoProfiles\profiles'
.\wap.ps1 config set workspaceRoot '%USERPROFILE%\Workspaces'
.\wap.ps1 config set logging.root '%LOCALAPPDATA%\WindowsAutoProfiles\Logs'
```

Quoted environment-variable tokens are stored literally in JSON and expanded
when WAP runs.

## PowerShell and administrator requirements

| Command area | Minimum PowerShell | Administrator required | Notes |
|---|---:|---|---|
| `init`, `config`, `profile status/list` | 5.1 | No | Repository-local operations. |
| `profile install` | 5.1 | Usually no | WAP itself does not require elevation; individual WinGet installers may prompt or elevate. |
| `profile activate/deactivate` | 5.1 | No | Writes current-user environment variables and PATH, plus current process environment. |
| `profile uninstall/delete` | 5.1 | No by default | Preserves workspace data and captured registry keys unless explicit cleanup flags are used. Package uninstallers may prompt independently. |
| `profile uninstall --remove-registry`, `profile cleanup --registry` | 5.1 | Only when HKLM keys are eligible | Tries Windows `sudo.exe` first for machine-wide HKLM registry cleanup; otherwise prints the exact elevated command. |
| `capture start/list/rename/validate/diff/applyfilter/remove` | 5.1 | No on host | `capture start` launches Sandbox and generates scripts. |
| `logs cleanup` | 5.1 | No | Removes generated command logs from `logging.root` except the current command log. |
| `Capture-Baseline.ps1` inside Sandbox | 5.1 | Yes | Tries `sudo.exe` first when not elevated; otherwise prints the exact elevated command. |
| `Capture-Finalize.ps1` inside Sandbox | 5.1 | Yes | Tries `sudo.exe` first when not elevated; otherwise prints the exact elevated command. |

If a Sandbox capture script is not elevated and Windows `sudo.exe` is not
available, the error includes a command like:

```text
powershell.exe -ExecutionPolicy Bypass -File "C:\WAPCapture\Capture-Finalize.ps1"
```

Run that command from an elevated PowerShell session inside Sandbox.

## Configuration

`wap.config.json` is a small bootstrap file that points to the full settings
file. By default, it points to `wap.settings.json` beside `wap.ps1`.

```json
{
  "version": 1,
  "configPath": "wap.settings.json"
}
```

`wap.settings.json` controls where workspaces are created, where profile
definitions are stored, how command logging behaves, and whether Sandbox
capture bootstraps WinGet by default.

```json
{
  "version": 1,
  "workspaceRoot": "%USERPROFILE%\\Workspaces",
  "profilesRoot": "profiles",
  "logging": {
    "enabled": true,
    "retentionDays": 30,
    "root": ".logs"
  },
  "sandbox": {
    "installWinget": true
  }
}
```

WAP expands environment variables and derives:

```text
profileRoot = workspaceRoot\<profileName>
sharedRoot  = workspaceRoot\_Shared
```

### Initialize the repository

```powershell
.\wap.ps1 init
```

Example output:

```text
WindowsAutoProfiles initialized at 'C:\src\WindowsAutoProfiles'.
```

`init` creates `wap.config.json` only when it is absent. It does not overwrite
existing configuration. It also creates `wap.settings.json` when that file is
absent.

`init` installs prerequisites by default. Skip prerequisite installation:

```powershell
.\wap.ps1 init --skip-prereqs
```

The first prerequisite is winget. If winget is missing, WAP first tries to
register Microsoft App Installer for the current user. If that does not make
winget available, WAP uses the official Microsoft.WinGet.Client repair path.

### Show configuration

```powershell
.\wap.ps1 config show
```

Example output:

```text
Configurable settings (use ".\wap.ps1 config set <key> <value>" on these keys only):

version               : 1
bootstrapConfigPath   : <local wap.config.json>
configPath            : wap.settings.json
workspaceRoot         : %USERPROFILE%\Workspaces
profilesRoot          : profiles
logging.enabled       : True
logging.retentionDays : 30
logging.root          : .logs
sandbox.installWinget : True

Dynamic resolved settings (read-only; computed at runtime from the configurable settings above):

local.bootstrapConfigPath    : C:\src\WindowsAutoProfiles\wap.config.json
resolved.bootstrapConfigPath : C:\src\WindowsAutoProfiles\wap.config.json
resolved.configPath          : C:\src\WindowsAutoProfiles\wap.settings.json
resolved.workspaceRoot       : C:\Users\me\Workspaces
resolved.profilesRoot        : C:\src\WindowsAutoProfiles\profiles
resolved.logging.root        : C:\src\WindowsAutoProfiles\.logs
```

### Set workspace root

```powershell
.\wap.ps1 config set workspaceRoot C:\Workspaces
```

Set the root where profile definitions and attached captures are stored:

```powershell
.\wap.ps1 config set profilesRoot '%OneDrive%\WindowsAutoProfiles\profiles'
```

### Configure logging

Command logging is enabled by default. Logs are written under `logging.root`
(`.logs\` by default) with a UTC timestamp in the file name. Failed commands
print the log path so users can attach the file to a GitHub issue.

Disable generated logs globally:

```powershell
.\wap.ps1 config set logging.enabled false
```

Move generated logs to another directory:

```powershell
.\wap.ps1 config set logging.root '%LOCALAPPDATA%\WindowsAutoProfiles\Logs'
```

If the directory does not exist, `config set` warns but does not create it. WAP
creates the directory when logging starts on the next command execution.

Enable logs again:

```powershell
.\wap.ps1 config set logging.enabled true
```

Set automatic retention to 14 days:

```powershell
.\wap.ps1 config set logging.retentionDays 14
```

Disable automatic deletion by setting retention to `0`:

```powershell
.\wap.ps1 config set logging.retentionDays 0
```

Clean all generated logs manually:

```powershell
.\wap.ps1 logs cleanup
```

Preview cleanup:

```powershell
.\wap.ps1 logs cleanup -WhatIf
```

Example output:

```text
workspaceRoot set to 'C:\Workspaces'.
```

Use `-WhatIf` to preview:

```powershell
.\wap.ps1 config set workspaceRoot D:\Profiles -WhatIf
```

## Profile schema

Profiles live under `<profilesRoot>\<name>\profile.yaml`.

Example:

```yaml
name: developer

apps:
  - id: Git.Git
  - id: Microsoft.VisualStudioCode
  - id: Microsoft.PowerShell

env:
  WAP_PROFILE: developer
  WAP_CONFIG_HOME: ${profileRoot}\Config

path:
  - ${profileRoot}\Apps\bin
  - ${sharedRoot}\bin

projects: ${profileRoot}\Projects
data: ${profileRoot}\Data
downloads: ${profileRoot}\Downloads
cache: ${profileRoot}\Cache

shortcuts:
  - name: Developer Tools
    target: ${profileRoot}\Apps\Tools\DeveloperTools.exe
```

Supported substitutions:

| Placeholder | Meaning |
|---|---|
| `${workspaceRoot}` | Configured workspace root |
| `${profileRoot}` | Workspace folder for this profile |
| `${sharedRoot}` | Shared workspace folder |
| `${profileName}` | Current profile name |

Normal Windows `%ENVIRONMENT_VARIABLE%` references are also expanded.

## Profile lifecycle

### Create an empty profile definition

```powershell
.\wap.ps1 profile new developer
```

The command creates `<profilesRoot>\developer\profile.yaml` with a minimal
editable profile:

```yaml
name: developer
apps:
  # - id: Git.Git
  #   source: winget
  #   enabled: true
captures:
  # - id: developer-settings
  #   enabled: true
env:
  WAP_PROFILE: developer
path:
  # - ${profileRoot}\Apps\bin
projects: ${profileRoot}\Projects
data: ${profileRoot}\Data
downloads: ${profileRoot}\Downloads
cache: ${profileRoot}\Cache
shortcuts:
  # - name: Example
  #   target: ${profileRoot}\Apps\Example.exe
```

### Install a profile

Add WinGet packages to the profile definition:

```powershell
.\wap.ps1 profile winget add developer Python.Python.3.13
.\wap.ps1 profile winget add developer Python.Python.3.13 --version 3.13.5
.\wap.ps1 profile winget add developer Microsoft.VisualStudioCode --source winget
.\wap.ps1 profile winget disable developer Microsoft.VisualStudioCode
.\wap.ps1 profile winget list developer
.\wap.ps1 profile show developer
```

`--source` defaults to `winget`. `--version` is optional; when present, WAP
passes it to WinGet as `--version <version>`. During install, WAP runs WinGet
with exact package IDs, the configured source, `--accept-package-agreements`,
and `--accept-source-agreements` so source/package prompts are answered
automatically. Every package has an `enabled` flag in `profile.yaml`; disabled
packages remain documented but are skipped by install and uninstall. Use
`profile winget enable|disable` to toggle the flag without editing YAML.

```powershell
.\wap.ps1 profile install developer
```

Example output:

```text
Installing profile 'developer'...
  Profile root: C:\Workspaces\developer
  Shared root:  C:\Workspaces\_Shared
  Directories:
    [create] C:\Workspaces\_Shared
    [create] C:\Workspaces\developer
    [create] C:\Workspaces\developer\Projects
    [create] C:\Workspaces\developer\Data
    [create] C:\Workspaces\developer\Downloads
    [create] C:\Workspaces\developer\Cache
  Packages: 3 declared (2 enabled)
    [check] Git.Git (source: winget)
    [installed] Git.Git
    [check] Microsoft.VisualStudioCode (source: winget)
    [ready] Microsoft.VisualStudioCode is already installed
    [check] Microsoft.PowerShell (source: winget)
    [installed] Microsoft.PowerShell
  Attached captures: 1 declared (1 enabled)
    [capture] developer-settings selected=base replay=base only
  Shortcuts: 1 declared
    [create] Developer Tools
  State saved.
Done: profile 'developer' installed.
```

Install creates directories, installs packages, creates shortcuts, and records
ownership in `.wap-state.json`. It does not activate user environment variables.
WinGet packages are installed before enabled attached captures are processed so
captured files and registry values can override installer defaults. Disabled
captures stay listed in `profile.yaml` but are skipped.

Preview first:

```powershell
.\wap.ps1 profile install developer -WhatIf
```

Test the install in Windows Sandbox without changing the host:

```powershell
.\wap.ps1 profile install developer --sandbox
```

This creates `.sandbox\profile-install\developer`, stages the same winget
prerequisites used by capture Sandbox bootstrapping, mounts the repository as
`C:\WAPRepo`, mounts profile definitions as `C:\WAPProfiles`, then opens a
visible Sandbox PowerShell window. Inside Sandbox it copies scripts to a
Sandbox-local repo, writes temporary Sandbox-local WAP config, runs
`.\wap.ps1 init`, and runs `.\wap.ps1 profile install developer`. The temporary
config points `profilesRoot` at `C:\WAPProfiles` and `workspaceRoot` at
`C:\WAPProfileSandbox\workspaces`, so host config paths that point to OneDrive
or other external locations do not leak into the Sandbox test. The host command
also prints phase changes and points to
`.sandbox\profile-install\developer\output\profile-install.log`.

After the initial install completes, the Sandbox PowerShell window remains open
at `C:\WAPProfileSandbox\repo`. You can manually run `profile list`,
`profile install`, `profile activate`, `profile deactivate`, and
`profile uninstall` against any mounted profile under `C:\WAPProfiles`. See
`docs\profile-sandbox-testing.md` for the full workflow.

### Activate a profile

```powershell
.\wap.ps1 profile activate developer
```

Example output:

```text
Activating profile 'developer'...
  Profile root: C:\Workspaces\developer
  Environment variables: 2 declared
    [set] WAP_PROFILE
    [set] WAP_CONFIG_HOME
  PATH fragments: 2 declared
    [add] C:\Workspaces\developer\Apps\bin
    [add] C:\Workspaces\_Shared\bin
  State saved.
Done: profile 'developer' activated. Open a new terminal for other processes to see user environment changes.
```

Activation sets user-level environment variables and user PATH entries. It also
updates the current PowerShell process so this terminal can use them
immediately. Already-running applications usually need to be restarted.

If another profile is active, WAP deactivates it first.

### Deactivate a profile

```powershell
.\wap.ps1 profile deactivate developer
```

Example output:

```text
Deactivating profile 'developer'...
  Environment variables: 2 owned
    [restore] WAP_PROFILE
    [restore] WAP_CONFIG_HOME
  PATH fragments: 2 owned
    [remove] C:\Workspaces\developer\Apps\bin
    [remove] C:\Workspaces\_Shared\bin
  State saved.
Done: profile 'developer' deactivated.
```

Deactivation restores variables only when they still match the value WAP
applied. If a variable changed after activation, WAP warns and leaves it alone.

### Uninstall a profile

```powershell
.\wap.ps1 profile uninstall developer
```

If the profile is active, uninstall automatically deactivates it first:

```text
Uninstalling profile 'developer'...
  Profile root: C:\Workspaces\developer
  Profile is active; deactivating it first.
Deactivating profile 'developer'...
  Environment variables: 2 owned
    [restore] WAP_PROFILE
    [restore] WAP_CONFIG_HOME
  PATH fragments: 2 owned
    [remove] C:\Workspaces\developer\Apps\bin
    [remove] C:\Workspaces\_Shared\bin
  State saved.
Done: profile 'developer' deactivated.
```

Uninstall then removes WAP-owned shortcuts and package ownership. By default,
it preserves workspace directories, user data, and captured registry keys:

```text
  [keep] Registry cleanup disabled. Use --remove-registry to delete added registry keys from attached captures.
  [keep] Workspace directories and user data under 'C:\Workspaces\developer'. Use --remove-user-data to delete them.
```

Use explicit destructive flags when you want a full cleanup as part of uninstall:

```powershell
.\wap.ps1 profile uninstall developer --remove-user-data --remove-registry
```

`--remove-user-data` deletes the profile workspace directory, for example
`C:\Workspaces\developer`. It does not delete the shared workspace
`C:\Workspaces\_Shared`.

`--remove-registry` deletes only registry keys that attached capture manifests
recorded as **Added** and that pass WAP's safety filter. Changed registry keys
are not deleted. Broad Windows keys such as `HKLM\Software\Microsoft\Windows`
and `HKCU\Software\Classes\Applications` are skipped. If eligible HKLM keys
remain, WAP tries Windows `sudo.exe`; if sudo is unavailable, it prints the
exact command to rerun from an elevated PowerShell session.

If a profile has already been uninstalled and you later want to remove leftover
workspace data or attached-capture registry keys, use:

```powershell
.\wap.ps1 profile cleanup developer --user-data --registry
```

Or remove both with:

```powershell
.\wap.ps1 profile cleanup developer --all
```

Preview destructive cleanup first:

```powershell
.\wap.ps1 profile cleanup developer --all -WhatIf
```

### Delete a profile definition

```powershell
.\wap.ps1 profile delete developer
```

`profile delete` removes `<profilesRoot>\<name>\` only when the profile is not
installed. It preserves workspace data and `.capture` history.

### Show profile status

```powershell
.\wap.ps1 profile status
```

Example output:

```text
Workspace root:  C:\Workspaces
Active profile: developer
Installed:      1

Name       Installed Status        ProfileRoot
----       --------- ------        -----------
developer       True Active        C:\Workspaces\developer
example        False Not installed C:\Workspaces\example
```

`profile list` is an alias for the same status view.

### Toggle or reference profile captures

`profile capture add` copies a finalized standalone capture into
`<profilesRoot>\<profile>\captures\<id>\` and writes a matching explicit
reference to `profile.yaml`:

```yaml
captures:
  - id: developer-settings
    enabled: true
```

Temporarily disable or re-enable a capture without deleting it:

```powershell
.\wap.ps1 profile capture disable developer developer-settings
.\wap.ps1 profile capture enable developer developer-settings
```

If a capture folder already exists under the profile but is missing from
`profile.yaml`, `profile capture list` shows it under **Unreferenced capture
folders**. Add it back to YAML and enable it with:

```powershell
.\wap.ps1 profile capture enable developer developer-settings
```

Whenever WAP writes `profile.yaml`, it normalizes older package/capture entries
to the current schema and adds missing `enabled` flags.

## Standalone captures

Standalone captures are raw Windows Sandbox capture sessions under:

```text
.capture\<name>\
```

They can be listed, renamed, validated, filtered, attached to profiles, and
removed.

### Start a capture

```powershell
.\wap.ps1 capture start kicad
```

By default, `capture start` installs winget inside the Windows Sandbox before
baseline capture starts. This keeps winget setup out of the captured application
diff while making winget available for interactive installer work. Skip this for
one capture with:

```powershell
.\wap.ps1 capture start kicad --no-winget
```

Example output:

```text
Starting interactive capture for profile 'kicad'...
  Host capture root: C:\src\WindowsAutoProfiles\.capture\kicad
  Sandbox winget bootstrap: enabled
  [created] baseline/
  [created] after/
  [created] output/
  [generated] Capture-Common.ps1
  [generated] Capture-Startup.ps1
  [generated] Capture-Baseline.ps1
  [generated] Capture-Finalize.ps1
  [generated] capture-filters.json
  [generated] sandbox.wsb
  [launch] Windows Sandbox
Sandbox launched.
Waiting for Sandbox baseline to finish (timeout: 900 seconds)...

=== BASELINE READY ===
Sandbox user: WIN11-SANDBOX\WDAGUtilityAccount
Sandbox profile: C:\Users\WDAGUtilityAccount

Inside Sandbox, finalize with:
  powershell.exe -ExecutionPolicy Bypass -File C:\WAPCapture\Capture-Finalize.ps1
```

The Sandbox baseline and finalize scripts require administrator rights. If they
are not elevated, they try Windows `sudo.exe` first. If sudo is unavailable,
they stop with the exact command to paste into an elevated Sandbox PowerShell
window.

### List captures

```powershell
.\wap.ps1 capture list
```

Example output:

```text
Standalone capture root: C:\src\WindowsAutoProfiles\.capture

Name  Status        CreatedAt            Path
----  ------        ---------            ----
kicad Finalized     2026-07-04T01:16:54Z C:\src\WindowsAutoProfiles\.capture\kicad
tools BaselineReady 2026-07-04T02:20:11Z C:\src\WindowsAutoProfiles\.capture\tools
```

### Rename a capture

```powershell
.\wap.ps1 capture rename kicad electronics-kicad
```

Example output:

```text
Renaming capture session 'kicad' to 'electronics-kicad'...
  [from] C:\src\WindowsAutoProfiles\.capture\kicad
  [to]   C:\src\WindowsAutoProfiles\.capture\electronics-kicad
Done: capture session 'kicad' renamed to 'electronics-kicad'.
```

### Validate or inspect a capture

```powershell
.\wap.ps1 capture validate electronics-kicad
.\wap.ps1 capture diff electronics-kicad
```

Example summary:

```text
Capture 'electronics-kicad' manifest validated.
Capture diff for 'electronics-kicad'
  Added files:                 30645
  Filtered file noise:         1847
  Changed registry keys:       76
  Filtered registry noise:     511
  New services:                0
  New shortcuts:               8
  Suspected uninstall commands: 3
  Filtered uninstall noise:    1
  Safety: nothing was deleted and no MSIX was generated.
```

### Reapply filters

```powershell
.\wap.ps1 capture applyfilter electronics-kicad
```

This reapplies `capture-filters.json` to an existing manifest and saves a
backup named `capture-manifest.before-applyfilter.json`.

### Remove a capture

```powershell
.\wap.ps1 capture remove electronics-kicad --Confirm
```

Example output:

```text
Deleting capture session 'electronics-kicad'...
  [delete] C:\src\WindowsAutoProfiles\.capture\electronics-kicad
  [keep] Profile definitions, workspace data, and WAP state are not touched.
Done: capture session 'electronics-kicad' deleted.
```

## Profile-attached captures

Attach a standalone capture to a profile:

```powershell
.\wap.ps1 profile capture add electronics electronics-kicad --id kicad --name "KiCad" --description "KiCad and user settings"
```

This copies the capture manifest into:

```text
profiles\electronics\captures\kicad\
```

The attached capture contains:

```text
capture-manifest.json
capture-filters.json
metadata.json
```

List attached captures:

```powershell
.\wap.ps1 profile capture list electronics
```

Example output:

```text
id    name  createdAt            addedAt                       description
--    ----  ---------            -------                       -----------
kicad KiCad 2026-07-04T01:16:54Z 2026-07-04T02:07:47.6425615Z KiCad and user settings
```

Edit metadata:

```powershell
.\wap.ps1 profile capture edit electronics kicad --name "KiCad 10" --description "KiCad 10 per-user install and shortcuts"
```

Refresh an attached capture from a newer standalone capture:

```powershell
.\wap.ps1 profile capture refresh electronics kicad kicad-refresh --description "KiCad 10.0.1 update" --apply
```

List and select capture versions:

```powershell
.\wap.ps1 profile capture versions electronics kicad
.\wap.ps1 profile capture select-version electronics kicad base
.\wap.ps1 profile capture select-version electronics kicad latest
```

Merge a known-good selected version into the base manifest:

```powershell
.\wap.ps1 profile capture merge electronics kicad
```

Copy a capture to another profile:

```powershell
.\wap.ps1 profile capture copy electronics kicad developer --id kicad
```

Remove a capture from a profile:

```powershell
.\wap.ps1 profile capture remove electronics kicad
```

This removes only the attached copy under `profiles\<profile>\captures\<id>\`.
It does not delete the standalone `.capture\<name>\` session.

See [Capture refresh and versioning](capture-versioning.md) for the full model
and reliability notes.

## Legacy package-list capture

```powershell
.\wap.ps1 capture new developer
```

This creates a profile YAML from currently installed WinGet packages. It is a
simple package-list capture and does not use Windows Sandbox.
