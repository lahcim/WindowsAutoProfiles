# Configuration reference

Version: 1.1

Last updated: 2026-07-04T02:24:12Z

Author: Michal Zygmunt <lahcim@fajne.com>

WindowsAutoProfiles stores local machine configuration in `wap.config.json` at
the repository root.

## Example configuration

```json
{
  "version": 1,
  "workspaceRoot": "%USERPROFILE%\\Workspaces",
  "logging": {
    "enabled": true,
    "retentionDays": 30
  }
}
```

## Options

| Key | Type | Default | Description |
|---|---|---:|---|
| `version` | integer | `1` | Configuration schema version. |
| `workspaceRoot` | string | `%USERPROFILE%\Workspaces` | Root where profile workspaces are created. Environment variables are expanded. |
| `logging.enabled` | boolean | `true` | Enables timestamped per-command logs under `.logs\`. |
| `logging.retentionDays` | integer | `30` | Deletes generated log files older than this many days after each command. Use `0` to disable automatic deletion. |

## Commands

Show current configuration:

```powershell
.\wap.ps1 config show
```

Example output:

```text
Version              : 1
WorkspaceRoot        : %USERPROFILE%\Workspaces
ResolvedWorkspaceRoot: C:\Users\me\Workspaces
LoggingEnabled       : True
LoggingRetentionDays : 30
LogRoot              : C:\src\WindowsAutoProfiles\.logs
ConfigPath           : C:\src\WindowsAutoProfiles\wap.config.json
```

Set the workspace root:

```powershell
.\wap.ps1 config set workspaceRoot C:\Workspaces
```

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
generated `.logs\*.log` files.
