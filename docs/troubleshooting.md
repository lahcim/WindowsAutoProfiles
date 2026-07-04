# Troubleshooting and logs

Version: 1.1

Last updated: 2026-07-04T02:24:12Z

Author: Michal Zygmunt <lahcim@fajne.com>

WindowsAutoProfiles is designed to produce enough detail for users to file
actionable GitHub issues when something goes wrong.

## Command logs

By default every `wap.ps1` invocation creates a detailed timestamped log under:

```text
.logs\
```

Example log path:

```text
C:\src\WindowsAutoProfiles\.logs\20260704T022412Z-profile-a1b2c3d4.log
```

At the end of a successful command, WAP prints:

```text
Detailed log file: C:\src\WindowsAutoProfiles\.logs\20260704T022412Z-profile-a1b2c3d4.log
```

If a command fails, WAP prints the error and explicitly points to the log:

```text
Command failed. Detailed logs are located at: C:\src\WindowsAutoProfiles\.logs\20260704T022412Z-profile-a1b2c3d4.log
Detailed log file: C:\src\WindowsAutoProfiles\.logs\20260704T022412Z-profile-a1b2c3d4.log
```

Logs include:

- WAP version and last updated timestamp
- command line
- repository path
- PowerShell version
- OS version
- command output
- warnings and errors
- verbose details emitted during execution

## What to attach to a GitHub issue

When reporting a bug, attach:

1. The generated `.logs\*.log` file printed by the failed command.
2. The exact command you ran.
3. The relevant `profile.yaml`, if the issue is profile-specific.
4. The relevant `metadata.json` and `capture-manifest.json`, if the issue is capture-specific.

Review logs and manifests before sharing publicly. They may include local paths,
package names, service command lines, registry key names, or application names.

## Disable logging

Disable logging for one command:

```powershell
.\wap.ps1 profile status --no-log
```

Disable logging globally:

```powershell
.\wap.ps1 config set logging.enabled false
```

Enable it again:

```powershell
.\wap.ps1 config set logging.enabled true
```

## Log retention

By default WAP removes generated logs older than 30 days after each command.

Change retention:

```powershell
.\wap.ps1 config set logging.retentionDays 14
```

Disable automatic deletion:

```powershell
.\wap.ps1 config set logging.retentionDays 0
```

## Manual log cleanup

Remove generated logs:

```powershell
.\wap.ps1 logs cleanup
```

Preview cleanup:

```powershell
.\wap.ps1 logs cleanup -WhatIf
```

## Windows Sandbox capture logs

Sandbox capture has its own logs inside the capture workspace:

```text
.capture\<name>\output\baseline.log
.capture\<name>\output\baseline-error.txt
.capture\<name>\baseline\baseline-status.json
```

Host command logs are still written under `.logs\` when you run commands such
as:

```powershell
.\wap.ps1 capture start kicad
.\wap.ps1 capture validate kicad
.\wap.ps1 capture applyfilter kicad
```

For capture failures, include both the host `.logs\*.log` file and the relevant
`.capture\<name>\output\*.txt` or `.log` files.
