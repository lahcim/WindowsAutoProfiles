# Scenario cookbook

This guide shows common WindowsAutoProfiles workflows end to end.

Version: 1.1

Last updated: 2026-07-04T08:17:28Z

Author: Michal Zygmunt <lahcim@fajne.com>

All commands require PowerShell 5.1 or newer. Host commands generally do not
need administrator rights; Sandbox capture baseline/finalize scripts do and
will try Windows `sudo.exe` before asking you to paste an exact command into an
elevated Sandbox PowerShell window.

## Scenario 1: Install a published profile

### 1. One-time direct install

```powershell
.\wap.ps1 install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
```

This initializes WAP when needed, checks prerequisites, downloads the remote
profile to temporary storage, installs it, activates it, and removes the
temporary files.

### 2. Download first, then install locally

```powershell
.\wap.ps1 profile download electronics https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
.\wap.ps1 profile install electronics
.\wap.ps1 profile activate electronics
```

This saves the profile definition under your configured `profilesRoot` as
`electronics`, so you can review or edit it before installing by local name.

Use GitHub folder URLs in this format:

```text
https://github.com/<owner>/<repo>/tree/<branch>/<path-to-profile-folder>
```

## Scenario 2: Create a new development profile

Create a new profile from the example:

```powershell
Copy-Item .\profiles\example .\profiles\developer -Recurse
notepad .\profiles\developer\profile.yaml
```

Edit the profile:

```yaml
name: developer

apps:
  - id: Git.Git
  - id: Microsoft.VisualStudioCode
  - id: Microsoft.PowerShell
  - id: OpenJS.NodeJS.LTS

env:
  WAP_PROFILE: developer
  DEV_HOME: ${profileRoot}

path:
  - ${profileRoot}\Apps\bin
  - ${sharedRoot}\bin

projects: ${profileRoot}\Projects
data: ${profileRoot}\Data
downloads: ${profileRoot}\Downloads
cache: ${profileRoot}\Cache
```

Preview:

```powershell
.\wap.ps1 profile install developer -WhatIf
```

Install and activate:

```powershell
.\wap.ps1 profile install developer
.\wap.ps1 profile activate developer
```

Confirm:

```powershell
.\wap.ps1 profile status
```

Example output:

```text
Workspace root:  C:\Workspaces
Active profile: developer
Installed:      1

Name      Installed Status ProfileRoot
----      --------- ------ -----------
developer      True Active C:\Workspaces\developer
example       False Not installed C:\Workspaces\example
```

## Scenario 3: Switch between two profiles

Assume `developer` and `electronics` are both installed:

```powershell
.\wap.ps1 profile activate electronics
```

If `developer` is active, WAP deactivates it first:

```text
Activating profile 'electronics'...
  Profile root: C:\Workspaces\electronics
  Switching from active profile 'developer'.
Deactivating profile 'developer'...
  Environment variables: 2 owned
    [restore] WAP_PROFILE
    [restore] DEV_HOME
  PATH fragments: 2 owned
    [remove] C:\Workspaces\developer\Apps\bin
    [remove] C:\Workspaces\_Shared\bin
  State saved.
Done: profile 'developer' deactivated.
  Environment variables: 1 declared
    [set] WAP_PROFILE
  PATH fragments: 1 declared
    [add] C:\Workspaces\electronics\Apps\bin
  State saved.
Done: profile 'electronics' activated. Open a new terminal for other processes to see user environment changes.
```

## Scenario 4: Add an interactive installer capture to a profile

Some tools are better captured after interactive setup. Start a standalone
capture:

```powershell
.\wap.ps1 capture start kicad
```

Wait for:

```text
=== BASELINE READY ===
```

Inside Windows Sandbox, install and configure KiCad. Then run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\WAPCapture\Capture-Finalize.ps1
```

Example Sandbox output:

```text
WindowsAutoProfiles capture: recording after-state.
Recording filesystem metadata...
Exporting registry...
Recording services and scheduled tasks...
Computing capture diff...
Capture finalized to C:\WAPCapture\output\capture-manifest.json
Added files:                 30645
Filtered file noise:         1847
Changed registry keys:       76
Filtered registry noise:     511
New services:                0
New shortcuts:               8
Suspected uninstall commands: 3
Filtered uninstall noise:    1
No files, registry keys, services, or tasks were deleted.
```

Back on the host:

```powershell
.\wap.ps1 capture validate kicad
.\wap.ps1 profile capture add electronics kicad --id kicad --name "KiCad" --description "KiCad per-user installation and shortcuts"
```

List attached captures:

```powershell
.\wap.ps1 profile capture list electronics
```

Clean up the raw standalone capture when you no longer need it:

```powershell
.\wap.ps1 capture remove kicad --Confirm
```

## Scenario 5: Rename a capture before attaching it

If you start with a temporary name:

```powershell
.\wap.ps1 capture start test1
```

After reviewing it, rename it:

```powershell
.\wap.ps1 capture rename test1 kicad
```

Attach it using the final name:

```powershell
.\wap.ps1 profile capture add electronics kicad --id kicad --name "KiCad"
```

## Scenario 6: Reuse one capture in multiple profiles

Attach the capture to the first profile:

```powershell
.\wap.ps1 profile capture add electronics kicad --id kicad --name "KiCad"
```

Copy the attached capture to another profile:

```powershell
.\wap.ps1 profile capture copy electronics kicad developer --id kicad
```

Each profile now has its own attached copy:

```text
profiles\electronics\captures\kicad\
profiles\developer\captures\kicad\
```

## Scenario 7: Update capture metadata

Use metadata to explain why a capture exists:

```powershell
.\wap.ps1 profile capture edit electronics kicad --name "KiCad 10" --description "KiCad 10 per-user files, Start Menu shortcuts, and uninstall metadata"
```

Example metadata:

```json
{
  "id": "kicad",
  "name": "KiCad 10",
  "description": "KiCad 10 per-user files, Start Menu shortcuts, and uninstall metadata",
  "createdAt": "2026-07-04T01:16:54Z",
  "addedAt": "2026-07-04T02:07:47.6425615Z",
  "updatedAt": "2026-07-04T02:30:10.1234567Z",
  "sourceCapture": "kicad",
  "manifest": "capture-manifest.json"
}
```

## Scenario 7: Remove a profile but keep data

Deactivate first if needed:

```powershell
.\wap.ps1 profile deactivate developer
```

Uninstall WAP ownership:

```powershell
.\wap.ps1 profile uninstall developer
```

Delete the profile definition if you no longer want it in the repository:

```powershell
.\wap.ps1 profile delete developer
```

The workspace folder remains:

```text
C:\Workspaces\developer
```

Delete that data manually only when you are certain it is no longer needed.

## Scenario 8: Recover from a failed or noisy capture

List standalone captures:

```powershell
.\wap.ps1 capture list
```

Example:

```text
Standalone capture root: C:\src\WindowsAutoProfiles\.capture

Name       Status         CreatedAt            Path
----       ------         ---------            ----
kicad      Finalized      2026-07-04T01:16:54Z C:\src\WindowsAutoProfiles\.capture\kicad
bad-run    BaselineFailed 2026-07-04T02:11:22Z C:\src\WindowsAutoProfiles\.capture\bad-run
```

Remove the failed run:

```powershell
.\wap.ps1 capture remove bad-run --Confirm
```

If filter rules changed after a successful capture, reapply them:

```powershell
.\wap.ps1 capture applyfilter kicad
.\wap.ps1 capture diff kicad
```

## Scenario 9: Publish or share profiles safely

Before publishing:

1. Review `<profilesRoot>\<name>\profile.yaml` for machine-specific paths.
2. Review `<profilesRoot>\<name>\captures\<id>\metadata.json` for private notes.
3. Review capture manifests before committing them; they can include local
   paths, service command lines, application names, and registry metadata.
4. Do not commit `.capture\`; it contains raw baseline and after snapshots and
   is ignored by Git.
5. Do not commit `.wap-state.json`; it is local machine state and is ignored by
   Git.

Useful checks:

```powershell
git status --short
git diff -- profiles docs README.md
```
