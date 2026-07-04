# Design and safety model

`wap.ps1` is a thin CLI wrapper around `src\WindowsAutoProfiles.psm1`. The
module owns profile parsing, state management, lifecycle operations, and the
Windows Sandbox capture workflow.

Version: 1.1

Last updated: 2026-07-04T02:24:12Z

Author: Michal Zygmunt <lahcim@fajne.com>

## Goals

- Keep profile definitions portable and reviewable.
- Separate installation from activation.
- Preserve user data by default.
- Track WAP-owned changes so they can be reversed safely.
- Keep interactive capture isolated in Windows Sandbox.
- Avoid applying captured changes automatically.

## Repository layout

```text
wap.ps1                         CLI entry point
src\WindowsAutoProfiles.psm1    PowerShell module
profiles\<name>\profile.yaml    Profile definitions
profiles\<name>\captures\       Profile-attached capture manifests
templates\capture\              Sandbox scripts and filter rules
docs\                           Documentation
tests\                          Pester tests
```

Runtime state is local and ignored by Git:

```text
.wap-state.json
.capture\
```

## Path model

`wap.config.json` is the single authority for workspace placement on the local
machine.

```json
{
  "version": 1,
  "workspaceRoot": "%USERPROFILE%\\Workspaces"
}
```

WAP expands environment variables, validates that the resolved path is
absolute, and derives:

```text
profileRoot = <workspaceRoot>\<profileName>
sharedRoot  = <workspaceRoot>\_Shared
```

Profile YAML should use placeholders instead of machine-specific paths:

```yaml
projects: ${profileRoot}\Projects
path:
  - ${profileRoot}\Apps\bin
  - ${sharedRoot}\bin
```

## Profile parsing

When `ConvertFrom-Yaml` is available, WAP uses it. Otherwise, WAP falls back to
a bundled simple YAML parser that supports the profile schema:

- top-level scalars
- top-level maps
- scalar lists
- lists of flat maps

This keeps the default setup lightweight while still allowing richer YAML
parsing when a YAML module is installed.

## State and ownership

`.wap-state.json` records the state WAP needs to make lifecycle operations
safe:

- installed profiles
- workspace and profile roots
- directories WAP created
- declared packages
- packages WAP installed
- shortcuts WAP created
- active profile
- environment values applied during activation
- PATH fragments added during activation

State writes go through a temporary file and then replace the state file.

## Lifecycle model

### Install

`profile install` prepares a profile but does not activate it:

- creates shared and profile-specific directories
- checks and installs declared WinGet packages
- creates declared shortcuts
- records installed state

### Activate

`profile activate` requires the profile to be installed. It:

- deactivates the previous active profile if needed
- sets declared user environment variables
- adds declared fragments to the user PATH
- mirrors those environment changes into the current PowerShell process
- records activation state

### Deactivate

`profile deactivate` reverses only the activation changes WAP owns:

- restores previous user environment variable values
- removes only PATH fragments WAP added
- clears active profile state

If an environment variable no longer matches the value WAP applied, WAP leaves
it unchanged and warns. This prevents deactivation from overwriting a later
manual or tool-driven change.

### Uninstall

`profile uninstall` removes WAP ownership of a profile:

- deactivates it if active
- removes recorded shortcuts
- uninstalls a recorded package only when no other installed profile declares it
- preserves profile workspace directories and data

Workspace deletion and registry deletion are intentionally not part of default
uninstall. They require explicit destructive flags:

```powershell
.\wap.ps1 profile uninstall <name> --remove-user-data --remove-registry
.\wap.ps1 profile cleanup <name> --user-data --registry
```

Registry cleanup removes only attached-capture registry keys recorded as
`Added` and accepted by WAP's safety filter. Changed keys are not deleted.

### Delete

`profile delete` removes the profile definition under `profiles\<name>\` only
when the profile is not installed. It does not delete workspace data or capture
history.

## Capture model

Sandbox captures are split into two stages:

1. `capture start <name>` creates `.capture\<name>\`, launches Windows Sandbox,
   records a baseline, and waits for baseline readiness.
2. `Capture-Finalize.ps1` runs inside Sandbox after the user installs or
   configures software. It records after-state, computes a diff, applies noise
   filters, and writes `output\capture-manifest.json`.

The host can then validate, filter, rename, attach, or remove the standalone
capture.

Standalone captures:

```text
.capture\<name>\
```

Profile-attached captures:

```text
profiles\<profile>\captures\<capture-id>\
```

Attaching a capture copies only the filtered evidence needed by the profile
library. It does not keep the full raw baseline and after snapshots.

## Capture filtering

Filters live in:

```text
templates\capture\capture-filters.json
```

New capture sessions copy this file into `.capture\<name>\`. Both the Sandbox
finalize script and the host `capture applyfilter` command use the same rules.

Filtering separates likely Windows/Sandbox noise from relevant changes:

- Edge profile/cache churn
- Explorer MRUs and shell bags
- jump lists and shader caches
- diagnostic logs
- scheduled-task cache duplicates
- certificate and identity cache churn
- built-in Edge uninstall commands

Filtered items remain in the manifest under `filtered*` arrays so they can be
audited later.

## Safety model

WAP prefers conservative operations:

- Every host CLI command validates PowerShell 5.1 or newer before dispatch.
- Sandbox capture scripts validate PowerShell 5.1 or newer before collecting
  state.
- Sandbox capture scripts require administrator rights, try Windows `sudo.exe`
  first when not elevated, and otherwise print the exact elevated command.
- All lifecycle commands support `-WhatIf` where they mutate local state.
- Existing capture sessions are not overwritten.
- Capture removal is limited to direct children of `.capture`.
- Capture rename is limited to direct children of `.capture`.
- Profile delete refuses installed profiles.
- Uninstall preserves workspace directories.
- User-data and registry cleanup require explicit flags.
- Deactivation does not overwrite changed environment variables.
- Sandbox capture reads state and writes evidence only.
- Captured changes are never applied automatically to the host.
- Registry deletion is limited to explicit cleanup of safe added keys from
  attached capture manifests.

## Testing

The repository uses Pester tests under `tests\`.

Run the suite:

```powershell
Invoke-Pester -Path .\tests -PassThru
```

The tests cover:

- config and profile parsing
- workspace path expansion
- install/activate/deactivate behavior
- capture session generation
- PowerShell 5.1 compatibility for capture scripts
- capture filtering
- capture listing, renaming, and removal
- profile-attached capture add/list/edit/copy/remove
