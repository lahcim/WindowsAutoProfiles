# Configuration reference

Version: 1.1

Last updated: 2026-07-04T03:24:14Z

Author: Michal Zygmunt <lahcim@fajne.com>

WindowsAutoProfiles uses a small bootstrap config plus a full settings config.
By default both files live beside `wap.ps1`:

- `wap.config.json` points to the full config file.
- `wap.settings.json` contains all regular settings.

This lets the tool live in one directory while profiles and full settings live
somewhere else, such as OneDrive.

## Example bootstrap config

```json
{
  "version": 1,
  "configPath": "wap.settings.json"
}
```

`configPath` supports environment variables and may be absolute or relative to
the active bootstrap config file directory. `bootstrapConfigPath` can move that
active bootstrap file; the local `wap.config.json` remains the fixed entry point
and stores that redirect.

## Example full config

```json
{
  "version": 1,
  "workspaceRoot": "%USERPROFILE%\\Workspaces",
  "profilesRoot": "%OneDrive%\\WindowsAutoProfiles\\profiles",
  "logging": {
    "enabled": true,
    "retentionDays": 30,
    "root": ".logs"
  }
}
```

## Options

| Key | Type | Default | Description |
|---|---|---:|---|
| `version` | integer | `1` | Configuration schema version. |
| `bootstrapConfigPath` | string | `<local wap.config.json>` | Local-bootstrap-only redirect to another bootstrap config. Environment variables are expanded at runtime. Relative paths resolve from the repository root. |
| `configPath` | string | `wap.settings.json` | Bootstrap-only path to the full config. Environment variables are expanded at runtime. Relative paths resolve from the active bootstrap config directory. |
| `workspaceRoot` | string | `%USERPROFILE%\Workspaces` | Root where profile workspaces are created. Environment variables are expanded. |
| `profilesRoot` | string | `profiles` | Root where profile definitions and attached captures are stored. Environment variables are expanded at runtime. Relative paths resolve from the full config file directory. |
| `logging.enabled` | boolean | `true` | Enables timestamped per-command logs under `logging.root`. |
| `logging.retentionDays` | integer | `30` | Deletes generated log files older than this many days after each command. Use `0` to disable automatic deletion. |
| `logging.root` | string | `.logs` | Root where generated command logs are written. Environment variables are expanded at runtime. Relative paths resolve from the repository root. |

## Commands

Show current configuration:

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
profilesRoot          : %OneDrive%\WindowsAutoProfiles\profiles
logging.enabled       : True
logging.retentionDays : 30
logging.root          : .logs

Dynamic resolved settings (read-only; computed at runtime from the configurable settings above):

local.bootstrapConfigPath    : C:\src\WindowsAutoProfiles\wap.config.json
resolved.bootstrapConfigPath : C:\src\WindowsAutoProfiles\wap.config.json
resolved.configPath          : C:\src\WindowsAutoProfiles\wap.settings.json
resolved.workspaceRoot       : C:\Users\me\Workspaces
resolved.profilesRoot        : C:\Users\me\OneDrive\WindowsAutoProfiles\profiles
resolved.logging.root        : C:\src\WindowsAutoProfiles\.logs
```

Move the active bootstrap config to OneDrive:

```powershell
.\wap.ps1 config set bootstrapConfigPath '%OneDrive%\WindowsAutoProfiles\wap.bootstrap.json'
```

Move the full config to OneDrive:

```powershell
.\wap.ps1 config set configPath '%OneDrive%\WindowsAutoProfiles\wap.settings.json'
```

Set the workspace root:

```powershell
.\wap.ps1 config set workspaceRoot C:\Workspaces
```

Store profile definitions and attached captures in OneDrive:

```powershell
.\wap.ps1 config set profilesRoot '%OneDrive%\WindowsAutoProfiles\profiles'
```

Store command logs in a custom location:

```powershell
.\wap.ps1 config set logging.root '%LOCALAPPDATA%\WindowsAutoProfiles\Logs'
```

`config set` validates and stores the path but does not create the logging
directory. If it does not exist yet, WAP prints a warning and creates it the
next time command logging starts. The command that changes `logging.root` keeps
using the previously active logging directory; the new path applies on the next
`wap.ps1` execution.

## Environment variables

Config values are stored exactly as provided and expanded only at runtime. Use
quotes in PowerShell when you want environment-variable tokens preserved in the
JSON file:

```powershell
.\wap.ps1 config set workspaceRoot '%USERPROFILE%\Workspaces'
.\wap.ps1 config set profilesRoot '%OneDrive%\WindowsAutoProfiles\profiles'
.\wap.ps1 config set bootstrapConfigPath '%OneDrive%\WindowsAutoProfiles\wap.bootstrap.json'
.\wap.ps1 config set configPath '%OneDrive%\WindowsAutoProfiles\wap.settings.json'
.\wap.ps1 config set logging.root '%LOCALAPPDATA%\WindowsAutoProfiles\Logs'
```

The stored JSON keeps `%USERPROFILE%` and `%OneDrive%`; WAP expands them each
time it loads configuration.

Disable command logging globally:

```powershell
.\wap.ps1 config set logging.enabled false
```

Enable command logging:

```powershell
.\wap.ps1 config set logging.enabled true
```

Set retention to 7 days:

```powershell
.\wap.ps1 config set logging.retentionDays 7
```

Disable automatic log deletion:

```powershell
.\wap.ps1 config set logging.retentionDays 0
```

## Per-command logging override

Use `--no-log` to disable logging for one invocation without changing
configuration:

```powershell
.\wap.ps1 profile status --no-log
```

## Log cleanup

Remove generated logs manually:

```powershell
.\wap.ps1 logs cleanup
```

Preview cleanup:

```powershell
.\wap.ps1 logs cleanup -WhatIf
```

`logs cleanup` keeps the current command's active log file and removes other
generated `*.log` files from the resolved logging root.
