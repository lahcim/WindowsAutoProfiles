# Profile testing in Windows Sandbox

Version: 1.1

Last updated: 2026-07-04T06:18:19Z

Author: Michal Zygmunt <lahcim@fajne.com>

Use Sandbox profile testing when you want to validate profile install,
activation, deactivation, and uninstall behavior without changing the host.

## Start a Sandbox test

Run from the repository root:

```powershell
.\wap.ps1 profile install <profile> --sandbox
```

WAP creates `.sandbox\profile-install\<profile>\`, stages WinGet prerequisites,
opens Windows Sandbox, and runs an initial install for the requested profile.
The Sandbox window stays open after the initial install so you can continue
testing manually.

## Sandbox layout

Inside Sandbox, WAP uses a temporary local configuration:

| Path | Purpose |
|---|---|
| `C:\WAPProfileSandbox\repo` | Sandbox-local copy of the WAP scripts. Run commands here. |
| `C:\WAPProfiles` | Read-only mount of the host profile definitions. |
| `C:\WAPProfileSandbox\workspaces` | Sandbox-only profile workspaces. |
| `C:\WAPProfileSandbox\output\logs` | Command logs created inside Sandbox. |
| `C:\WAPProfileSandbox\profile-testing.md` | Generated quick reference inside Sandbox. |

The temporary config points `profilesRoot` at `C:\WAPProfiles` and
`workspaceRoot` at `C:\WAPProfileSandbox\workspaces`, so host config paths such
as OneDrive folders are not used inside Sandbox.

## Manual lifecycle commands

After the initial install completes, use the visible Sandbox PowerShell window.
It is left at `C:\WAPProfileSandbox\repo`.

If PowerShell blocks scripts, enable script execution for only the current
Sandbox PowerShell process:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\wap.ps1 profile list
.\wap.ps1 profile show <profile>
.\wap.ps1 profile install <profile>
.\wap.ps1 profile activate <profile>
.\wap.ps1 profile deactivate <profile>
.\wap.ps1 profile uninstall <profile>
.\wap.ps1 profile uninstall <profile> --remove-user-data --remove-registry
```

You can run these commands against any profile mounted under `C:\WAPProfiles`,
not only the profile used to launch the Sandbox.

## Editing profiles

Profile definitions are mounted read-only inside Sandbox. Edit profiles on the
host, then rerun:

```powershell
.\wap.ps1 profile install <profile> --sandbox
```

This creates a fresh Sandbox session with the latest profile definitions.
