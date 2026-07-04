# WindowsAutoProfiles

WindowsAutoProfiles (WAP) is a PowerShell tool for creating repeatable Windows
workspaces from versioned YAML profiles.

Version: 1.1

Last updated: 2026-07-04T04:48:53Z

Author: Michal Zygmunt <lahcim@fajne.com>

Use it to describe a workspace once, then recreate its folders, WinGet
packages, shortcuts, user environment variables, and profile-specific `PATH`
entries on a Windows machine. WAP also includes an optional Windows Sandbox
capture workflow for observing interactive installers and attaching the
resulting evidence to profiles.

## Why use WAP?

Windows development machines tend to accumulate global state: packages, PATH
entries, shortcuts, app data, registry settings, and project folders. WAP keeps
the intentional parts of that setup in a repository so a workspace can be
reviewed, rebuilt, switched, and cleaned up predictably.

WAP is designed around a few principles:

- **Profiles are portable.** Profile YAML uses placeholders such as
  `${profileRoot}` and `${sharedRoot}` instead of hard-coded machine paths.
- **User data is preserved.** Uninstall removes WAP-owned shortcuts and package
  ownership state, but it does not delete workspace directories.
- **Activation is reversible.** WAP records the user environment changes it
  applies and restores only those values during deactivation.
- **Capture is evidence, not installation.** Sandbox capture records what
  changed; it does not apply captured changes to the host.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 or newer
- WinGet for package installation
- Windows Sandbox for interactive capture workflows
- PowerShell execution policy that allows running `wap.ps1`

The host CLI explicitly checks for PowerShell 5.1 or newer before running each
command. Sandbox capture scripts also check for PowerShell 5.1 or newer.

Most host-side commands do not require an elevated shell because they operate on
the current user's environment and workspace. Sandbox capture baseline/finalize
scripts require administrator rights inside the Sandbox so they can collect the
best available service, scheduled-task, HKLM, and filesystem metadata. If those
scripts are not elevated, they first try Windows `sudo.exe`; if `sudo.exe` is
not available, they print the exact elevated command to run.

## Quick start

Clone the repository and initialize the local configuration:

```powershell
git clone https://github.com/<owner>/WindowsAutoProfiles.git
Set-Location .\WindowsAutoProfiles
.\wap.ps1 init
.\wap.ps1 --examples
```

By default, `init` also checks/install prerequisites such as winget when
missing. To skip prerequisite installation:

```powershell
.\wap.ps1 init --skip-prereqs
```

Configure where profile workspaces should be created:

```powershell
.\wap.ps1 config set workspaceRoot '%USERPROFILE%\Workspaces'
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

Optionally store full settings and profile definitions in OneDrive:

```powershell
.\wap.ps1 config set configPath '%OneDrive%\WindowsAutoProfiles\wap.settings.json'
.\wap.ps1 config set profilesRoot '%OneDrive%\WindowsAutoProfiles\profiles'
.\wap.ps1 config set logging.root '%LOCALAPPDATA%\WindowsAutoProfiles\Logs'
```

Changing `logging.root` affects the next command execution. `config set` warns
if the directory does not exist; WAP creates it when command logging starts.

Create an empty placeholder profile under the configured `profilesRoot`:

```powershell
.\wap.ps1 profile new developer
notepad <profilesRoot>\developer\profile.yaml
```

Update the profile name and package list:

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
```

Preview the install:

```powershell
.\wap.ps1 profile install developer -WhatIf
```

Install and activate it:

```powershell
.\wap.ps1 profile install developer
.\wap.ps1 profile activate developer
```

Open a new terminal for all user-level environment changes to be visible to new
processes.

## Core concepts

### Profile

A profile is a directory under `<profilesRoot>\<name>\` containing
`profile.yaml`. It describes packages, workspace folders, environment
variables, PATH entries, and shortcuts for one workspace.

### Configuration roots

`wap.config.json` is a small bootstrap file that points to the full settings
file:

```json
{
  "version": 1,
  "configPath": "wap.settings.json"
}
```

The full settings file controls workspace and profile-definition roots:

```json
{
  "version": 1,
  "workspaceRoot": "%USERPROFILE%\\Workspaces",
  "profilesRoot": "%OneDrive%\\WindowsAutoProfiles\\profiles"
}
```

Environment-variable tokens are stored literally in JSON and expanded at
runtime. For a profile named `developer`, WAP derives:

```text
profileRoot = <workspaceRoot>\developer
sharedRoot  = <workspaceRoot>\_Shared
```

### Install vs. activate

`profile install` prepares the profile:

- creates the profile and shared workspace directories
- installs declared WinGet packages first, accepting package/source agreements
  for non-interactive setup
- applies/records attached captures after WinGet packages, so captures can
  override files or registry values created by package installers
- creates declared shortcuts
- records ownership in `.wap-state.json`

`profile activate` switches the user environment to that installed profile:

- sets declared user environment variables
- adds declared profile PATH fragments to the user PATH
- updates the current PowerShell process environment
- records the active profile in `.wap-state.json`

`profile deactivate` reverses the environment changes WAP recorded during
activation. It does not uninstall packages, delete folders, or remove shortcuts.

## Common commands

```powershell
.\wap.ps1 init
.\wap.ps1 config show
.\wap.ps1 config set workspaceRoot C:\Workspaces

.\wap.ps1 profile status
.\wap.ps1 profile new developer
.\wap.ps1 profile winget add developer Python.Python.3.13
.\wap.ps1 profile winget add developer Microsoft.VisualStudioCode --source winget
.\wap.ps1 profile winget list developer
.\wap.ps1 profile show developer
.\wap.ps1 profile install developer -WhatIf
.\wap.ps1 profile install developer --sandbox
.\wap.ps1 profile install developer
.\wap.ps1 profile activate developer
.\wap.ps1 profile deactivate developer
.\wap.ps1 profile uninstall developer
.\wap.ps1 profile cleanup developer --user-data --registry
.\wap.ps1 profile delete developer

.\wap.ps1 capture start kicad
.\wap.ps1 capture list
.\wap.ps1 capture rename kicad electronics-kicad
.\wap.ps1 capture validate electronics-kicad
.\wap.ps1 profile capture add developer electronics-kicad --id kicad --name "KiCad"
.\wap.ps1 profile capture list developer
.\wap.ps1 profile winget remove developer Python.Python.3.13
.\wap.ps1 capture remove electronics-kicad
```

Use `profile install <name> --sandbox` to open a disposable Windows Sandbox
that installs one profile first, then remains open for manual
install/activate/deactivate/uninstall testing of any mounted profile. See
`docs\profile-sandbox-testing.md`.

## Windows Sandbox capture

Some tools require interactive installers or create per-user files that are not
represented by a WinGet package alone. WAP can launch Windows Sandbox, capture a
baseline, let you install/configure software interactively, then compute a diff.

High-level flow:

```powershell
.\wap.ps1 capture start kicad
```

`capture start` installs winget inside the Sandbox before baseline capture by
default. Use `--no-winget` to skip this for a single capture, or set
`sandbox.installWinget` to `false` to change the default.

Wait for:

```text
=== BASELINE READY ===
```

Inside Sandbox, install and configure the application. Then run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\WAPCapture\Capture-Finalize.ps1
```

Back on the host:

```powershell
.\wap.ps1 capture validate kicad
.\wap.ps1 profile capture add electronics kicad --id kicad --name "KiCad"
```

Standalone captures live under `.capture\<name>\`. They are ignored by Git and
can be removed after they are no longer needed:

```powershell
.\wap.ps1 capture remove kicad
```

## Documentation

- [Usage and command reference](docs/usage.md)
- [Configuration reference](docs/configuration.md)
- [Scenario cookbook](docs/scenarios.md)
- [Windows Sandbox capture](docs/capture.md)
- [Capture refresh and versioning](docs/capture-versioning.md)
- [Troubleshooting and logs](docs/troubleshooting.md)
- [Design and safety model](docs/design.md)

## Repository layout

```text
wap.ps1                         CLI entry point
src\WindowsAutoProfiles.psm1    PowerShell module implementation
profiles\example\profile.yaml   Starter profile
templates\capture\              Windows Sandbox capture templates
docs\                           User and developer documentation
tests\                          Pester tests
```

Runtime files are intentionally ignored by Git:

```text
.wap-state.json
.capture\
.logs\
```

## Safety notes

- Use `-WhatIf` before mutating profile lifecycle commands.
- `profile uninstall` automatically deactivates the profile first when it is
  active.
- WAP does not delete workspace folders or captured registry keys during normal
  uninstall.
- Use `profile uninstall <name> --remove-user-data --remove-registry` or
  `profile cleanup <name> --user-data --registry` only when you intentionally
  want destructive cleanup.
- WAP deactivation does not overwrite environment variables that changed after
  activation.
- Sandbox capture does not apply captured files or registry values to the host.
- Review capture manifests before sharing them because they can include local
  paths, package names, service command lines, and application settings.

## Troubleshooting logs

By default every CLI invocation writes a timestamped detailed log under
`logging.root` (`.logs\` by default). The command prints the log path at the
end, and failed commands also print where to find the detailed log. Logs are
ignored by Git and are intended for GitHub issues.

Disable logging for one command:

```powershell
.\wap.ps1 profile status --no-log
```

Disable logging globally:

```powershell
.\wap.ps1 config set logging.enabled false
```

Remove generated logs:

```powershell
.\wap.ps1 logs cleanup
```
