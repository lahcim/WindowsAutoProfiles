# Example profiles

Version: 1.1

Last updated: 2026-07-04T08:38:26Z

Author: Michal Zygmunt <lahcim@fajne.com>

This repository includes example profile definitions under `profiles\`.

## developer

Path:

```text
profiles\developer
```

Purpose:

- Git
- PowerShell
- Python
- Visual Studio Code
- GitHub CLI

Install directly from GitHub:

```powershell
wap install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/developer
```

Or from a local checkout:

```powershell
.\wap.ps1 profile install developer
.\wap.ps1 profile activate developer
```

See `profiles\developer\README.md` for profile-specific notes.

## electronics

Path:

```text
profiles\electronics
```

Purpose:

- Arduino IDE
- KiCad

Install directly from GitHub:

```powershell
wap install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
```

Or from a local checkout:

```powershell
.\wap.ps1 profile install electronics
.\wap.ps1 profile activate electronics
```

See `profiles\electronics\README.md` for profile-specific notes.
