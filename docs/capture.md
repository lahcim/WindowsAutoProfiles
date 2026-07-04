# Interactive Windows Sandbox capture

WindowsAutoProfiles can observe an installation inside disposable Windows
Sandbox and produce evidence for a future profile. It does not apply the diff,
delete anything, or generate MSIX packages.

Version: 1.1

Last updated: 2026-07-04T03:58:01Z

Author: Michal Zygmunt <lahcim@fajne.com>

Windows Sandbox must be enabled in Windows Features.
Generated capture scripts explicitly target Windows PowerShell 5.1, and the WSB startup command invokes `powershell.exe` rather than PowerShell 7.
The baseline and finalize scripts explicitly validate PowerShell 5.1 or newer.
They also require administrator rights inside Sandbox. When not elevated, they
first try Windows `sudo.exe`; if `sudo.exe` is unavailable, they stop and print
the exact elevated command to run.

## Workflow

Start a standalone session on the host:

```powershell
.\wap.ps1 capture start example
```

By default, WAP installs winget inside the Windows Sandbox before baseline
capture starts. That startup step uses the Microsoft.WinGet.Client
`Repair-WinGetPackageManager -AllUsers` path and runs before
`Capture-Baseline.ps1`, so the baseline does not accidentally capture winget
installation changes. Use `--no-winget` to skip winget setup for a single
capture:

```powershell
.\wap.ps1 capture start example --no-winget
```

The global default is controlled by:

```powershell
.\wap.ps1 config set sandbox.installWinget true
```

This creates `.capture/example/` under the repository root. That folder is the
raw capture workspace you can later list, rename, attach to profiles, or delete.
It contains:

```text
baseline/
after/
output/
sandbox.wsb
session.json
Capture-Common.ps1
Capture-Startup.ps1
Capture-Baseline.ps1
Capture-Finalize.ps1
```

The generated `sandbox.wsb` maps only `.capture/example` to
`C:\WAPCapture` with read/write enabled. Its startup command runs
`C:\WAPCapture\Capture-Startup.ps1`, which optionally bootstraps winget before
running `C:\WAPCapture\Capture-Baseline.ps1`.

The baseline records filesystem metadata under Program Files, Program Files
(x86), ProgramData, AppData Roaming, AppData Local, and both user/common Start
Menu locations. It also exports `HKCU\Software` and `HKLM\Software`, and records
services and scheduled tasks. The host command waits until the baseline writes
`=== BASELINE READY ===`; do not install applications before that message. The
sandbox remains open afterward. Baseline and finalize scripts show PowerShell
progress bars while capturing files, registry, services, tasks, and diffs.

The baseline and after snapshots record the Sandbox current user, including the
qualified name, SID, elevation state, and profile path such as
`C:\Users\WDAGUtilityAccount`. The finalized manifest carries this in
`captureContext` so later profile generation can remap Sandbox user paths and
registry values to the target WAP user on the dev box.

Install and configure applications manually. Then, inside Sandbox, run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\WAPCapture\Capture-Finalize.ps1
```

That records the after-state, computes a diff, and writes:

```text
C:\WAPCapture\output\capture-manifest.json
```

Back on the host, validate the finalized capture or view it again:

```powershell
.\wap.ps1 capture list
.\wap.ps1 capture validate example
.\wap.ps1 capture diff example
.\wap.ps1 capture applyfilter example
```

If the capture name is not the one you want to use later, rename it before
attaching it to profiles:

```powershell
.\wap.ps1 capture rename example kicad
```

The summary reports added files, changed/added registry keys, new services, new
shortcuts, and suspected uninstall commands. The manifest additionally records
changed files, added directories, and new scheduled tasks.

Capture data can be large and may contain machine-specific paths, registry
values, service command lines, or application names. `.capture/` is ignored by
Git. Review manifests before sharing them.

Registry comparison streams large `.reg` files and reports per-file progress.
Only uninstall registry value lines are retained in memory for suspected
uninstall command detection; other keys retain hashes only. Common Windows
runtime churn such as Explorer MRUs, shell bags, tile/cache state, IdentityCRL,
certificate auto-update cache, scheduled-task cache duplicates, and Edge profile
churn is separated into `filteredRegistryKeys`; app-specific keys remain in
`changedRegistryKeys`.

File comparison similarly separates common Windows/Sandbox churn into
`filteredAddedFiles`, including Edge profile/cache files, jump lists, shader
caches, TokenBroker/credential caches, packaged-app runtime files, diagnostic
logs, and temporary debug logs. Application payloads such as
`AppData\Local\Programs\KiCad` remain in `addedFiles`.

Uninstall command detection filters known built-in Microsoft Edge uninstallers
into `filteredUninstallCommands`; application uninstallers remain in
`suspectedUninstallCommands`.

Filter rules live in `capture-filters.json`. New capture sessions copy this
file next to the Sandbox scripts, and `capture applyfilter <name>` can reapply
updated rules to an existing `output/capture-manifest.json`.

Captures are standalone artifacts until attached to a profile. This lets one
small capture be reused across multiple profiles:

```powershell
.\wap.ps1 profile capture add dev kicad --id kicad --name "KiCad" --description "Electronics tools"
.\wap.ps1 profile capture list dev
.\wap.ps1 profile capture edit dev kicad --description "KiCad and related settings"
.\wap.ps1 profile capture copy dev kicad electronics
.\wap.ps1 profile capture remove dev kicad
```

Attached captures are stored under
`profiles\<profile>\captures\<capture-id>\` with `capture-manifest.json` plus
`metadata.json` containing id, name, description, created/added/updated
timestamps, and source capture information.

Delete a leftover capture session when you are ready to start over with the
same name, or after it has been attached to the profiles that need it:

```powershell
.\wap.ps1 capture remove example
```

## Safety

- Capture scripts only read system state and write snapshots to `C:\WAPCapture`.
- No files, registry keys, services, tasks, or applications are removed.
- No captured changes are applied to the host.
- No MSIX package is generated.
- Existing capture sessions are never overwritten; choose a new name or remove
  the old session with `capture remove <name>`.

The older package-list capture remains available:

```powershell
.\wap.ps1 capture new example
```

## Baseline readiness and troubleshooting

Do not install anything until the startup window prints `=== BASELINE READY ===`.
A successful baseline contains `baseline/baseline-status.json` with
`"success": true` and `baseline/snapshot.json`.

Startup diagnostics are written to:

```text
output/baseline.log
output/baseline-error.txt
baseline/baseline-status.json
```

Services are collected with CIM retries and a `Get-Service`/registry fallback.
Scheduled tasks use `Get-ScheduledTask` with a bounded `schtasks.exe` fallback.
Windows Sandbox can deny CIM access even when the shell is elevated; those
warnings are non-fatal when the fallback completes. If `schtasks.exe` also
hangs or fails, WAP records an empty scheduled-task snapshot and continues
instead of blocking the capture.

If the banner says `BASELINE FAILED`, or finalize reports a missing/incomplete
baseline, do not reuse that evidence as a baseline—especially if applications
were already installed. Close Sandbox, preserve or rename the failed `.capture`
session for diagnosis, then start a clean session. Existing sessions are never
overwritten or deleted automatically.

If a capture script reports that administrator rights are required, open an
elevated PowerShell session inside Sandbox and run the exact command shown in
the error, for example:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\WAPCapture\Capture-Finalize.ps1"
```
