# WindowsAutoProfiles CLI reference

Version: 1.1

Last updated: 2026-07-04T06:56:18Z

Author: Michal Zygmunt <lahcim@fajne.com>

This is the expanded command reference for `wap.ps1`. Run commands from the
repository root unless stated otherwise.

## Global commands and options

| Command | Description |
|---|---|
| `.\wap.ps1 --help` | Print the built-in help text. |
| `.\wap.ps1 --examples` | Print `docs\examples.md`. |
| `.\wap.ps1 init [--skip-prereqs] [-WhatIf]` | Create config/state folders and files. By default, also checks or installs prerequisites such as WinGet. |
| `--no-log` | Global option accepted by every command to disable command logging for that invocation. |
| `-WhatIf` | Supported by mutating commands that create, delete, install, or rewrite files/config. |

## Configuration commands

| Command | Description |
|---|---|
| `.\wap.ps1 config show` | Show configurable settings and resolved runtime paths. |
| `.\wap.ps1 config set bootstrapConfigPath <path> [-WhatIf]` | Store a local redirect to another bootstrap config. Relative paths resolve from the repository root. |
| `.\wap.ps1 config set configPath <path> [-WhatIf]` | Set the full settings file path in the active bootstrap config. Relative paths resolve from the active bootstrap config directory. |
| `.\wap.ps1 config set workspaceRoot <path> [-WhatIf]` | Set the root where installed profile workspaces are created. Must resolve to an absolute path. |
| `.\wap.ps1 config set profilesRoot <path> [-WhatIf]` | Set the root where profile definitions and attached captures are stored. Relative paths resolve from the full config file directory. |
| `.\wap.ps1 config set logging.enabled <true|false> [-WhatIf]` | Enable or disable generated command logs. |
| `.\wap.ps1 config set logging.retentionDays <days> [-WhatIf]` | Set generated-log retention. Use `0` to disable automatic deletion. |
| `.\wap.ps1 config set logging.root <path> [-WhatIf]` | Set the generated-log directory. Relative paths resolve from the repository root. |
| `.\wap.ps1 config set sandbox.installWinget <true|false> [-WhatIf]` | Control whether `capture start` bootstraps WinGet in Sandbox by default. |
| `.\wap.ps1 logs cleanup [-WhatIf]` | Delete generated logs from `logging.root`, keeping the current command log. |

## Profile lifecycle commands

| Command | Description |
|---|---|
| `.\wap.ps1 profile status` | Show workspace root, active profile, installed count, and profile table. |
| `.\wap.ps1 profile list` | Alias for `profile status`. |
| `.\wap.ps1 profile show <name>` | Show one profile's definition path, roots, WinGet packages, attached captures, and unreferenced capture folders. |
| `.\wap.ps1 profile new <name> [-WhatIf]` | Create a starter `<profilesRoot>\<name>\profile.yaml`. |
| `.\wap.ps1 profile install <name> [-WhatIf]` | Create directories, install enabled profile and capture-owned WinGet packages, create shortcuts, and save install state. |
| `.\wap.ps1 profile install <name> --sandbox [-WhatIf]` | Launch a disposable Windows Sandbox profile-install test and leave it open for manual lifecycle testing. |
| `.\wap.ps1 profile activate <name> [-WhatIf]` | Apply the profile's user environment variables and PATH fragments. |
| `.\wap.ps1 profile deactivate <name> [-WhatIf]` | Restore environment variables and PATH entries owned by the active profile. |
| `.\wap.ps1 profile uninstall <name> [--remove-user-data] [--remove-registry] [-WhatIf]` | Deactivate if needed, remove WAP-owned shortcuts/package ownership, and optionally delete profile data or eligible capture-added registry keys. |
| `.\wap.ps1 profile cleanup <name> [--user-data] [--registry] [--all] [-WhatIf]` | Cleanup user data or eligible capture-added registry keys after install/uninstall. |
| `.\wap.ps1 profile delete <name> [-WhatIf]` | Delete an uninstalled profile definition directory. Workspace data and `.capture` sessions are preserved. |

## Profile WinGet commands

| Command | Description |
|---|---|
| `.\wap.ps1 profile winget add <profile> <packageId> [--source <source>]` | Add an enabled package to the profile `apps:` list. Source defaults to `winget`. |
| `.\wap.ps1 profile winget list <profile>` | List package id, source, and enabled state. |
| `.\wap.ps1 profile winget enable <profile> <packageId> [--source <source>]` | Mark a package enabled without editing YAML. |
| `.\wap.ps1 profile winget disable <profile> <packageId> [--source <source>]` | Keep a package documented but skip it during install/uninstall. |
| `.\wap.ps1 profile winget remove <profile> <packageId> [--source <source>] [-WhatIf]` | Remove a package entry from `apps:`. Specify `--source` when duplicate IDs exist with different sources. |

During install, WAP checks whether each enabled package is already installed,
then runs WinGet exact-id install with package/source agreements accepted. The
per-package timeout defaults to 900 seconds and can be overridden for the
process with `WAP_WINGET_INSTALL_TIMEOUT_SECONDS`.

## Standalone capture commands

| Command | Description |
|---|---|
| `.\wap.ps1 capture new <name>` | Create an older package-list style profile capture. |
| `.\wap.ps1 capture start <name> [--no-winget] [-WhatIf]` | Start an interactive Windows Sandbox capture session under `.capture\<name>\`. |
| `.\wap.ps1 capture list` | List standalone capture sessions. |
| `.\wap.ps1 capture rename <name> <newName> [-WhatIf]` | Rename a standalone capture session. |
| `.\wap.ps1 capture validate <name>` | Validate dry-run safety flags and capture-local package references, then show a diff summary. |
| `.\wap.ps1 capture diff <name>` | Show the finalized capture summary. |
| `.\wap.ps1 capture applyfilter <name>` | Reapply current filter rules to an existing finalized manifest. |
| `.\wap.ps1 capture remove <name> [-WhatIf]` | Delete a standalone `.capture\<name>\` session. Profile definitions and state are not touched. |

`capture start` bootstraps WinGet inside Sandbox by default before baseline
capture. Use `--no-winget` for a single session, or set
`sandbox.installWinget=false` globally.

## Profile capture commands

| Command | Description |
|---|---|
| `.\wap.ps1 profile capture add <profile> <capture> [--id <id>] [--name <name>] [--description <text>]` | Attach a finalized standalone capture to a profile and add a matching enabled `captures:` reference. |
| `.\wap.ps1 profile capture list <profile>` | List attached captures with enabled state and selected version. |
| `.\wap.ps1 profile capture enable <profile> <captureId>` | Enable an existing capture reference. If an attached capture folder is unreferenced, this adds it to `profile.yaml` and enables it. |
| `.\wap.ps1 profile capture disable <profile> <captureId>` | Keep a capture attached but skip it during install. |
| `.\wap.ps1 profile capture remove <profile> <captureId> [-WhatIf]` | Remove the attached capture from the profile. |
| `.\wap.ps1 profile capture copy <fromProfile> <captureId> <toProfile> [--id <id>] [--name <name>] [--description <text>]` | Copy an attached capture to another profile. |
| `.\wap.ps1 profile capture edit <profile> <captureId> [--name <name>] [--description <text>]` | Edit capture metadata. |
| `.\wap.ps1 profile capture refresh <profile> <captureId> <capture> [--description <text>] [--apply]` | Add a refresh version from a finalized standalone capture; `--apply` selects it immediately. |
| `.\wap.ps1 profile capture versions <profile> <captureId>` | List base and refresh versions. |
| `.\wap.ps1 profile capture select-version <profile> <captureId> <base|latest|version>` | Select which capture version chain should be replayed by profile install. |
| `.\wap.ps1 profile capture merge <profile> <captureId> [--up-to <version>]` | Merge refresh versions into the base manifest and back up the previous manifest. |

Capture-owned packages live in
`<profilesRoot>\<profile>\captures\<captureId>\profile.yaml`. They are not
mixed into the parent profile's `apps:` list, so disabling a capture skips the
capture-owned package installs without affecting explicitly listed profile
packages.
