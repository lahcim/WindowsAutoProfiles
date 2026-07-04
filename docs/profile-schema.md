# Profile schema reference

Version: 1.1

Last updated: 2026-07-04T08:38:26Z

Author: Michal Zygmunt <lahcim@fajne.com>

Profiles live at:

```text
<profilesRoot>\<profileName>\profile.yaml
```

The `name` field must match the profile directory name. Profile names may use
letters, numbers, dots, underscores, and hyphens, and must start with a letter
or number.

## Complete example

```yaml
name: developer

apps:
  - id: Git.Git
    source: winget
    version: 2.50.1
    enabled: true
  - id: Anysphere.Cursor
    source: winget
    enabled: false

captures:
  - id: vscode
    enabled: true

env:
  WAP_PROFILE: developer
  WAP_CONFIG_HOME: ${profileRoot}\Config

path:
  - ${profileRoot}\Apps\bin
  - ${sharedRoot}\bin

projects: ${profileRoot}\Projects
data: ${profileRoot}\Data
downloads: ${profileRoot}\Downloads
cache: ${profileRoot}\Cache

shortcuts:
  - name: Developer Tools
    target: ${profileRoot}\Apps\Tools\DeveloperTools.exe
    location: Desktop
```

## Top-level fields

| Field | Required | Type | Description |
|---|---|---|---|
| `name` | Yes | string | Profile name. Must match the folder name. |
| `apps` | No | list | WinGet package entries explicitly owned by the profile. |
| `captures` | No | list | Attached capture references to apply after profile packages. |
| `env` | No | map | User environment variables to set during activation. |
| `path` | No | list of strings | User PATH fragments to add during activation. |
| `projects` | No | string | Override the default `Projects` directory. |
| `data` | No | string | Override the default `Data` directory. |
| `downloads` | No | string | Override the default `Downloads` directory. |
| `cache` | No | string | Override the default `Cache` directory. |
| `shortcuts` | No | list | Shortcuts to create during install. |

WAP always creates these profile directories during install:

| Directory label | Default path |
|---|---|
| `Apps` | `${profileRoot}\Apps` |
| `Config` | `${profileRoot}\Config` |
| `Projects` | `${profileRoot}\Projects` |
| `Data` | `${profileRoot}\Data` |
| `Downloads` | `${profileRoot}\Downloads` |
| `Cache` | `${profileRoot}\Cache` |
| `Temp` | `${profileRoot}\Temp` |

Only `projects`, `data`, `downloads`, and `cache` are currently configurable in
YAML. `Apps`, `Config`, and `Temp` use their defaults.

## Package entries

Short form:

```yaml
apps:
  - Git.Git
```

Expanded form:

```yaml
apps:
  - id: Git.Git
    source: winget
    version: 2.50.1
    enabled: true
```

| Field | Default | Description |
|---|---|---|
| `id` | required | Exact WinGet package ID. |
| `source` | `winget` | WinGet source to use. |
| `version` | not set | Optional WinGet package version. When omitted, WinGet installs the default/latest available version for that ID/source. |
| `enabled` | `true` | Disabled packages remain documented but are skipped by install/uninstall. |

Use CLI commands to keep YAML normalized:

```powershell
.\wap.ps1 profile winget add developer Git.Git
.\wap.ps1 profile winget add developer Git.Git --version 2.50.1
.\wap.ps1 profile winget disable developer Git.Git
.\wap.ps1 profile winget enable developer Git.Git
.\wap.ps1 profile winget remove developer Git.Git
```

## Capture references

Short form:

```yaml
captures:
  - vscode
```

Expanded form:

```yaml
captures:
  - id: vscode
    enabled: true
```

Capture references point to attached capture folders under:

```text
<profilesRoot>\<profile>\captures\<captureId>\
```

If a capture includes Sandbox-detected WinGet packages, those packages are
stored in the capture-local `profile.yaml` in that folder. They are installed
only when the capture reference is enabled.

## Environment and PATH

`env` is applied by `profile activate` and restored by `profile deactivate`.
`path` entries are added to the user PATH during activation and removed during
deactivation.

Already-running applications may not see user environment changes until they
are restarted. Open a new terminal after activation.

## Shortcuts

String shortcut form:

```yaml
shortcuts:
  - ${profileRoot}\Apps\Example.exe
```

Expanded shortcut form:

```yaml
shortcuts:
  - name: Example
    target: ${profileRoot}\Apps\Example.exe
    location: Desktop
```

| Field | Default | Description |
|---|---|---|
| `target` | required | Shortcut target path. |
| `name` | target file name without extension | Shortcut display name. |
| `location` | `Desktop` | `Desktop` or `StartMenu`. Other values currently fall back to Desktop. |

## Substitutions

WAP expands these placeholders in supported string fields:

| Placeholder | Meaning |
|---|---|
| `${workspaceRoot}` | Resolved workspace root from configuration. |
| `${profileRoot}` | `<workspaceRoot>\<profileName>`. |
| `${sharedRoot}` | `<workspaceRoot>\_Shared`. |
| `${profileName}` | Current profile name. |

Normal Windows `%ENVIRONMENT_VARIABLE%` references are expanded afterward.

## Capture-local profile schema

Attached captures may contain:

```text
<profilesRoot>\<profile>\captures\<captureId>\profile.yaml
```

That file uses the same `apps:` package-entry schema, but it is scoped to the
capture. `capture validate` checks that any `newWingetPackages` recorded in
`capture-manifest.json` have matching references in the capture-local
`profile.yaml`, and that the capture-local profile does not list extra packages
not present in the manifest.
