# Electronics profile

The `electronics` profile is an example WindowsAutoProfiles profile for
electronics, embedded, and PCB design work.

## Included packages

Enabled WinGet packages:

- `ArduinoSA.IDE.stable`
- `KiCad.KiCad`

The profile sets `WAP_PROFILE=electronics` and creates the standard profile
workspace folders such as `Projects`, `Data`, `Downloads`, and `Cache`.

## Install

From the repository root:

```powershell
.\wap.ps1 profile install electronics -WhatIf
.\wap.ps1 profile install electronics
.\wap.ps1 profile activate electronics
```

Open a new terminal after activation so user-level environment changes are
visible to new processes.
