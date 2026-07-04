# Capture refresh and versioning

Version: 1.1

Last updated: 2026-07-04T02:47:33Z

Author: Michal Zygmunt <lahcim@fajne.com>

Profile captures can evolve over time. For example, Visual Studio Code may
auto-update after a profile has already captured the original install. WAP
supports adding a later standalone capture as a **versioned diff patch** on top
of the profile-attached base capture.

## Model

An attached capture starts with:

```text
profiles\<profile>\captures\<capture-id>\capture-manifest.json
profiles\<profile>\captures\<capture-id>\metadata.json
```

Each refresh adds a diff-only version:

```text
profiles\<profile>\captures\<capture-id>\versions\v0001\capture-delta.json
profiles\<profile>\captures\<capture-id>\versions\v0002\capture-delta.json
```

`metadata.json` tracks:

- `selectedVersion`
- `versions[]`
- source standalone capture for each version
- description and timestamps

`selectedVersion = base` means only `capture-manifest.json` is selected.
`selectedVersion = v0002` means WAP considers base + `v0001` + `v0002` selected.

## Refresh workflow

Create a new standalone capture after the app has updated:

```powershell
.\wap.ps1 capture start vscode-refresh
```

Inside Sandbox, install/configure the newer app state and finalize:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\WAPCapture\Capture-Finalize.ps1
```

Back on the host, validate it:

```powershell
.\wap.ps1 capture validate vscode-refresh
```

Add it as a versioned diff patch:

```powershell
.\wap.ps1 profile capture refresh developer vscode vscode-refresh --description "VS Code update to 1.102"
```

Select it for the profile immediately:

```powershell
.\wap.ps1 profile capture refresh developer vscode vscode-refresh --description "VS Code update to 1.102" --apply
```

## Inspect versions

```powershell
.\wap.ps1 profile capture versions developer vscode
```

Example output:

```text
Capture 'vscode' on profile 'developer'
Selected version: v0001

version createdAt                    sourceCapture  description
------- ---------                    -------------  -----------
v0001  2026-07-04T02:40:00.0000000Z vscode-refresh VS Code update to 1.102
```

## Roll back or move forward

Select the base capture only:

```powershell
.\wap.ps1 profile capture select-version developer vscode base
```

Select the latest refresh:

```powershell
.\wap.ps1 profile capture select-version developer vscode latest
```

Select a specific version:

```powershell
.\wap.ps1 profile capture select-version developer vscode v0001
```

## Merge known-good versions

After validating that applying through a selected version works, merge the
selected version into the base manifest:

```powershell
.\wap.ps1 profile capture merge developer vscode
```

WAP creates a backup first:

```text
capture-manifest.before-merge-20260704T024000Z.json
```

Then it folds selected diff arrays into `capture-manifest.json`, clears merged
version entries, and resets `selectedVersion` to `base`.

Merge through a specific version:

```powershell
.\wap.ps1 profile capture merge developer vscode --up-to v0001
```

## Install behavior

During `profile install`, WAP prints attached captures and their selected
version chain:

```text
Attached captures: 1 declared
  [capture] vscode selected=v0001 replay=v0001
```

This makes the intended patch sequence visible and records it in `.wap-state`.

## Reliability and limitations

Refresh versions are reliable as **evidence and metadata diffs** when the newer
capture adds clearly identifiable files, registry keys, shortcuts, services, or
uninstall commands.

Current limitations:

- Existing capture manifests store file metadata, not file payload bytes.
- Existing registry diffs store key identity, not full registry value payloads
  for every key.
- A refresh can detect newly added manifest items, but it cannot perfectly
  detect value-only changes inside a registry key that already existed in the
  previous manifest.
- Broad Windows runtime churn is still filtered by `capture-filters.json`.
- Full replay/materialization of captured file and registry payloads requires
  future capture payload support.

Recommended workflow:

1. Create a refresh capture.
2. Add it without `--apply`.
3. Inspect `profile capture versions`.
4. Select the new version in a test profile.
5. Validate install behavior.
6. Merge only after the selected version is known-good.
