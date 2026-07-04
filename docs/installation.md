# Installation and package behavior

Version: 1.1

Last updated: 2026-07-04T08:38:26Z

Author: Michal Zygmunt <lahcim@fajne.com>

## MSI install

The MSI installs WAP per user under:

```text
%LOCALAPPDATA%\WindowsAutoProfiles
```

It includes `wap.cmd` and adds the install folder to the current user's PATH.
Open a new terminal after installing the MSI, then initialize once:

```powershell
wap init
```

`wap init` creates:

```text
%LOCALAPPDATA%\WindowsAutoProfiles\wap.config.json
%LOCALAPPDATA%\WindowsAutoProfiles\wap.settings.json
%LOCALAPPDATA%\WindowsAutoProfiles\.wap-state.json
%LOCALAPPDATA%\WindowsAutoProfiles\profiles\
%LOCALAPPDATA%\WindowsAutoProfiles\.logs\
```

Default profile workspaces are created under:

```text
%USERPROFILE%\Workspaces
```

## Direct remote install

```powershell
wap init
wap install https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
```

`wap install <github-profile-url>` downloads the profile to temporary storage,
installs it, activates it, and removes the temporary files. It does not save the
profile definition locally.

## Download first, then install locally

```powershell
wap init
wap profile download electronics https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
wap profile install electronics
wap profile activate electronics
```

If the profile already exists locally, refresh it with `--force`:

```powershell
wap profile download electronics https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics --force
```

## ZIP package

The ZIP package includes `wap.cmd`, but extracting the ZIP does not modify PATH.
Either run `.\wap.ps1` from the extracted folder or add that folder to PATH
manually.

## Source checkout

```powershell
git clone https://github.com/<owner>/WindowsAutoProfiles.git
Set-Location .\WindowsAutoProfiles
.\wap.ps1 init
```

When running from source, use `.\wap.ps1` instead of `wap`.

## GitHub profile URL format

Use GitHub folder URLs in this format:

```text
https://github.com/<owner>/<repo>/tree/<branch>/<path-to-profile-folder>
```

Example:

```text
https://github.com/lahcim/WindowsAutoProfiles/tree/main/profiles/electronics
```
