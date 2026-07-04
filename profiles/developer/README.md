# Developer profile

The `developer` profile is an example WindowsAutoProfiles profile for general
software development and AI-assisted coding.

## Included packages

Enabled WinGet packages:

- `Git.Git`
- `GoLang.Go`
- `OpenJS.NodeJS.LTS`
- `Chocolatey.Chocolatey`
- `Python.Python.3.13`
- `GitHub.cli`
- `GitHub.Copilot`
- `OpenAI.Codex`
- `Anthropic.ClaudeCode`

Disabled package kept in the profile for optional use:

- `Anysphere.Cursor`

The profile also references the `vscode` capture. Capture-owned packages and
configuration live under `captures\vscode\` rather than in this profile's main
`profile.yaml`.

## Install

From the repository root:

```powershell
.\wap.ps1 profile install developer -WhatIf
.\wap.ps1 profile install developer
.\wap.ps1 profile activate developer
```

Open a new terminal after activation so user-level environment changes are
visible to new processes.
