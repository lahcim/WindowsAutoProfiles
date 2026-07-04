# WindowsAutoProfiles

WindowsAutoProfiles (WAP) is a PowerShell wrapper around WinGet that organizes
packages into versioned Windows app profiles. Profiles can also include explicit
captures for applications installed outside WinGet and for custom user
configuration discovered in Windows Sandbox.

Version: 1.1

Last updated: 2026-07-04T07:21:54Z

Author: Michal Zygmunt <lahcim@fajne.com>

Use it to describe a Windows app profile once, then recreate its WinGet
packages, folders, shortcuts, user environment variables, and profile-specific
`PATH` entries on a Windows machine. WAP also includes a Windows Sandbox capture
workflow for explicitly recording non-WinGet installers and configuration
changes, then attaching that captured evidence to profiles.

## Fastest path: install a profile from GitHub

### 1. One-time direct install

```powershell
.\wap.ps1 install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
```

This initializes WAP if needed, checks prerequisites, downloads the remote
profile to a temporary folder, installs it, activates it, and removes the
temporary files. It does **not** save the profile definition locally.

### 2. Download first, then install locally

```powershell
.\wap.ps1 profile download electronics https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
.\wap.ps1 profile install electronics
.\wap.ps1 profile activate electronics
```

This downloads the profile into your configured `profilesRoot` as
`electronics`, so you can review or edit it before installing it by local name.

Use GitHub folder URLs in this format:

```text
https://github.com/<owner>/<repo>/tree/<branch>/<path-to-profile-folder>
```

## Why use WAP?

Windows development machines tend to accumulate global state: packages, PATH
entries, shortcuts, app data, registry settings, and project folders. WAP keeps
the intentional parts of that setup in a repository so a workspace can be
reviewed, rebuilt, switched, and cleaned up predictably.

WAP is designed around a few principles:

- **WinGet is the default package layer.** Profiles list intentional WinGet
  packages explicitly instead of inferring all packages from a machine.
- **Profiles are portable.** Profile YAML uses placeholders such as
  `${profileRoot}` and `${sharedRoot}` instead of hard-coded machine paths.
- **User data is preserved.** Uninstall removes WAP-owned shortcuts and package
  ownership state, but it does not delete workspace directories.
- **Activation is reversible.** WAP records the user environment changes it
  applies and restores only those values during deactivation.
- **Capture is explicit evidence.** Sandbox capture records non-WinGet
  installers and custom configuration changes; it does not infer packages from
  the host or apply captured changes to the host.

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
    source: winget
    enabled: true
  - id: Microsoft.VisualStudioCode
    source: winget
    enabled: true
  - id: Microsoft.PowerShell
    source: winget
    enabled: true

captures:
  - id: developer-settings
    enabled: true

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

## Example profiles

This repository includes ready-to-try profiles under `profiles\`:

| Profile | Purpose | Main packages |
|---|---|---|
| `developer` | General software development and AI-assisted coding tools | Git, Go, Node.js LTS, Chocolatey, Python 3.13, GitHub CLI, GitHub Copilot, OpenAI Codex, Claude Code; Cursor is present but disabled |
| `electronics` | Electronics, embedded, and PCB design work | Arduino IDE and KiCad |

Review a profile before installing it:

```powershell
notepad .\profiles\developer\profile.yaml
notepad .\profiles\electronics\profile.yaml
```

Preview, install, and activate one of the examples:

```powershell
.\wap.ps1 profile install developer -WhatIf
.\wap.ps1 profile install developer
.\wap.ps1 profile activate developer
```

Replace `developer` with `electronics` to install the electronics profile:

```powershell
.\wap.ps1 profile install electronics -WhatIf
.\wap.ps1 profile install electronics
.\wap.ps1 profile activate electronics
```

Profile-specific notes are included in:

- `profiles\developer\README.md`
- `profiles\electronics\README.md`

## Core concepts

### Profile

A profile is a directory under `<profilesRoot>\<name>\` containing
`profile.yaml`. It describes packages, workspace folders, environment
variables, PATH entries, and shortcuts for one workspace.

### Configuration files

WAP uses a two-file configuration model:

- `wap.config.json` is the repository-local entry point.
- `wap.settings.json` is the full settings file.

The local bootstrap file can also redirect to another bootstrap config with
`bootstrapConfigPath`, which lets one repository checkout point at settings and
profiles stored in OneDrive or another synced folder.

```json
{
  "version": 1,
  "configPath": "wap.settings.json"
}
```

The full settings file supports the current schema:

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

| Key | Default | Purpose |
|---|---|---|
| `bootstrapConfigPath` | local `wap.config.json` | Optional local redirect to another bootstrap config. |
| `configPath` | `wap.settings.json` | Path from the active bootstrap config to the full settings file. |
| `workspaceRoot` | `%USERPROFILE%\Workspaces` | Root where installed profile workspaces are created. |
| `profilesRoot` | `profiles` | Root containing profile definitions and attached captures. |
| `logging.enabled` | `true` | Enables per-command detailed logs. |
| `logging.retentionDays` | `30` | Deletes generated logs older than this many days; `0` disables automatic deletion. |
| `logging.root` | `.logs` | Directory for generated command logs. |
| `sandbox.installWinget` | `true` | Bootstraps WinGet in Sandbox before capture baseline by default. |

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

## Command reference

Run `.\wap.ps1 --help` for the authoritative command list. Current commands:

```powershell
.\wap.ps1 --help
.\wap.ps1 --examples
.\wap.ps1 install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
.\wap.ps1 init
.\wap.ps1 init --skip-prereqs
.\wap.ps1 config show
.\wap.ps1 config set bootstrapConfigPath <path>
.\wap.ps1 config set configPath <path>
.\wap.ps1 config set workspaceRoot C:\Workspaces
.\wap.ps1 config set profilesRoot <path>
.\wap.ps1 config set logging.enabled <true|false>
.\wap.ps1 config set logging.retentionDays <days>
.\wap.ps1 config set logging.root <path>
.\wap.ps1 config set sandbox.installWinget <true|false>
.\wap.ps1 logs cleanup

.\wap.ps1 profile status
.\wap.ps1 profile list
.\wap.ps1 profile show developer
.\wap.ps1 profile new developer
.\wap.ps1 profile download electronics https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
.\wap.ps1 profile install developer -WhatIf
.\wap.ps1 profile install developer --sandbox
.\wap.ps1 profile install developer
.\wap.ps1 profile activate developer
.\wap.ps1 profile deactivate developer
.\wap.ps1 profile uninstall developer
.\wap.ps1 profile uninstall developer --remove-user-data --remove-registry
.\wap.ps1 profile cleanup developer --user-data --registry
.\wap.ps1 profile cleanup developer --all
.\wap.ps1 profile delete developer

.\wap.ps1 profile winget add developer Python.Python.3.13
.\wap.ps1 profile winget add developer Microsoft.VisualStudioCode --source winget
.\wap.ps1 profile winget list developer
.\wap.ps1 profile winget disable developer Python.Python.3.13
.\wap.ps1 profile winget enable developer Python.Python.3.13
.\wap.ps1 profile winget remove developer Python.Python.3.13

.\wap.ps1 capture new package-list
.\wap.ps1 capture start kicad
.\wap.ps1 capture start kicad --no-winget
.\wap.ps1 capture list
.\wap.ps1 capture rename kicad electronics-kicad
.\wap.ps1 capture validate electronics-kicad
.\wap.ps1 capture diff electronics-kicad
.\wap.ps1 capture applyfilter electronics-kicad
.\wap.ps1 capture remove electronics-kicad

.\wap.ps1 profile capture add developer electronics-kicad --id kicad --name "KiCad"
.\wap.ps1 profile capture list developer
.\wap.ps1 profile capture disable developer kicad
.\wap.ps1 profile capture enable developer kicad
.\wap.ps1 profile capture edit developer kicad --description "KiCad evidence"
.\wap.ps1 profile capture copy developer kicad electronics
.\wap.ps1 profile capture refresh electronics kicad kicad-refresh --apply
.\wap.ps1 profile capture versions electronics kicad
.\wap.ps1 profile capture select-version electronics kicad latest
.\wap.ps1 profile capture merge electronics kicad --up-to v0001
.\wap.ps1 profile capture remove developer kicad
```

Most mutating commands support `-WhatIf`; every command supports the global
`--no-log` option.

Use `install <url>` when you want a one-shot remote install that does not save
the profile definition locally. Use `profile download <name> <url>` when you
want to persist the remote profile under your configured `profilesRoot` first,
review or edit it, and install it later:

```powershell
.\wap.ps1 profile download electronics https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
.\wap.ps1 profile install electronics
.\wap.ps1 profile activate electronics
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

- [Documentation index](docs/index.md)
- [Usage and command reference](docs/usage.md)
- [CLI reference](docs/cli-reference.md)
- [Configuration reference](docs/configuration.md)
- [Profile schema reference](docs/profile-schema.md)
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
profiles\developer\             Developer example profile
profiles\electronics\           Electronics example profile
templates\capture\              Windows Sandbox capture templates
docs\                           User and developer documentation
tests\                          Pester tests
```

Runtime files are intentionally ignored by Git:

```text
.wap-state.json
.capture\
.sandbox\
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
