# WindowsAutoProfiles

WindowsAutoProfiles (WAP) installs and switches Windows app profiles. A profile
can declare WinGet packages, folders, shortcuts, environment variables, PATH
entries, and optional Windows Sandbox capture data for installers that are not
fully represented by WinGet.

Version: 1.1

Last updated: 2026-07-04T08:45:34Z

Author: Michal Zygmunt <lahcim@fajne.com>

## Why WAP?

WAP is not just a WinGet wrapper with named profiles. WinGet installs apps;
WAP turns those apps into repeatable Windows workspaces by combining packages,
folders, shortcuts, environment variables, PATH entries, and captured
installer/configuration state.

The long-term vision is a **Windows Workspace Manager**: something closer to
Docker Compose for Windows desktop environments. For example:

```powershell
wap install https://github.com/lahcim/workspaces/electronics
```

After a few minutes, that workspace could include KiCad, shared libraries,
project templates, VS Code extensions, terminal settings, environment
variables, workspace folders, and Start Menu entries -- everything needed to
start working in that context.

## Fastest path: install a profile from GitHub

After installing the MSI, open a new terminal and initialize WAP once:

```powershell
wap init
```

Then install and activate a published profile directly:

```powershell
wap install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
```

Or download it first, review/edit it locally, then install it:

```powershell
wap profile download electronics https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
wap profile install electronics
wap profile activate electronics
```

If the local profile already exists, refresh it with:

```powershell
wap profile download electronics https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics --force
```

GitHub profile URLs use this format:

```text
https://github.com/<owner>/<repo>/tree/<branch>/<path-to-profile-folder>
```

## Install from source

```powershell
git clone https://github.com/<owner>/WindowsAutoProfiles.git
Set-Location .\WindowsAutoProfiles
.\wap.ps1 init
.\wap.ps1 --examples
```

From source, replace `wap` with `.\wap.ps1` in the examples above.

## Common commands

| Task | Command |
|---|---|
| Initialize config/state | `wap init` |
| Direct remote install | `wap install <github-profile-url>` |
| Download a profile definition | `wap profile download <name> <github-profile-url> [--force]` |
| Install a local profile | `wap profile install <name>` |
| Activate a profile | `wap profile activate <name>` |
| Add a WinGet package | `wap profile winget add <profile> <packageId> [--source <source>] [--version <version>]` |
| List profile packages | `wap profile winget list <profile>` |
| Uninstall a profile | `wap profile uninstall <name>` |
| Delete an uninstalled profile definition | `wap profile remove <name> --Confirm` |
| Start a Sandbox capture | `wap capture start <name>` |
| Delete a standalone capture | `wap capture remove <name> --Confirm` |

WinGet versions are optional. When `--version` is omitted, WinGet installs the
default/latest available version for the package ID and source.

## What WAP manages

- **Install** creates workspace folders, installs enabled WinGet packages,
  creates shortcuts, applies enabled captures, and records ownership in
  `.wap-state.json`.
- **Activate** applies user environment variables and PATH fragments for one
  installed profile.
- **Deactivate** reverses only the environment/PATH changes WAP recorded.
- **Uninstall** removes WAP-owned package installs and shortcuts, but keeps
  workspace data unless you pass cleanup flags.
- **Capture** uses Windows Sandbox to record installer/configuration evidence
  for tools that need interactive setup.

## Installed MSI behavior

The MSI installs WAP per user under:

```text
%LOCALAPPDATA%\WindowsAutoProfiles
```

It adds that folder to the current user's PATH and provides `wap.cmd`. `wap init`
creates config and state beside the installed script:

```text
%LOCALAPPDATA%\WindowsAutoProfiles\wap.config.json
%LOCALAPPDATA%\WindowsAutoProfiles\wap.settings.json
%LOCALAPPDATA%\WindowsAutoProfiles\.wap-state.json
%LOCALAPPDATA%\WindowsAutoProfiles\profiles\
%LOCALAPPDATA%\WindowsAutoProfiles\.logs\
```

Default workspaces are created under `%USERPROFILE%\Workspaces`.

## Example profiles

This repository includes two sample profiles:

| Profile | Purpose | Docs |
|---|---|---|
| `developer` | Git, PowerShell, Python, VS Code, GitHub CLI | `profiles\developer\README.md` |
| `electronics` | Arduino IDE and KiCad | `profiles\electronics\README.md` |

Install them directly from GitHub or from a local checkout:

```powershell
wap install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/developer
wap install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
```

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 or newer
- WinGet for package installation
- Windows Sandbox for capture workflows
- PowerShell execution policy that allows running WAP scripts

Most host commands do not require elevation. Some WinGet installers may prompt
or elevate independently. Sandbox baseline/finalize scripts require
administrator rights inside the Sandbox.

## Documentation

Start here:

- `docs\installation.md` - MSI/ZIP/source install behavior and config paths
- `docs\usage.md` - guided command walkthrough
- `docs\cli-reference.md` - full command reference
- `docs\profile-schema.md` - `profile.yaml` schema, including package versions
- `docs\configuration.md` - `wap.config.json` and `wap.settings.json`
- `docs\capture.md` - Windows Sandbox capture workflow
- `docs\scenarios.md` - cookbook workflows
- `docs\troubleshooting.md` - logs and diagnostics
- `docs\index.md` - complete documentation index

## Safety notes

WAP tracks ownership before removing things. Profile uninstall does not delete
workspace data by default, profile deletion refuses installed profiles, and
standalone capture removal requires `--Confirm`.
