---
type: kb
title: WinGet is missing or cannot open its source in remote Windows sessions
symptom: App Installer is present, but winget is not recognized or fails with 0x8a15000f over WinRM
status: solved
date: 2026-07-13
updated: 2026-07-13
component: windows-baseline
tags:
  - winget
  - powershell
  - winrm
  - appx
scope: context
context: hyperv-nestlab
---

# 0023 — WinGet is missing or cannot open its source in remote Windows sessions

## Symptom

Windows Server 2025 reports `Microsoft.DesktopAppInstaller` from `Get-AppxPackage -AllUsers`,
but `Get-Command winget.exe` returns nothing in a newly used WinRM account. After registering App
Installer, `winget source update` succeeds but `winget install` or `winget show` can still fail:

```text
0x8a15000f : Data required by the source is missing
```

## Environment

- Windows Server 2025 with Desktop Experience
- App Installer staged for all users
- Ansible over WinRM, including domain administrator accounts that have not logged on interactively

## Cause

App Installer and the pre-indexed WinGet community source are MSIX packages. Being staged for all
users does not guarantee that their App Execution Alias and extension are registered in the current
remote user's package graph. Calling the executable under another user's `WindowsApps` directory is
not a workaround; it fails with access denied.

## Fix

1. Register App Installer for the current remote user with Microsoft's documented
   `Add-AppxPackage -RegisterByFamilyName` command.
2. Run `winget source update --name winget`.
3. Register the downloaded `Microsoft.Winget.Source` manifest in the current package graph.
4. Run the normal latest-release command:

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Automation adds silent, agreement, and non-interactive flags. The `windows_baseline` Ansible role
skips all WinGet work when `pwsh.exe` is already present.

## Lessons

- Staged AppX/MSIX packages and per-user registration are different states.
- Do not weaken ACLs on `C:\Program Files\WindowsApps` or execute another user's alias.
- Verify both the WinGet CLI alias and the source extension when automating through WinRM.
- Keep the package command simple when the requirement is the latest stable release.

## Related

- `KB/0017-run-ps1-with-pwsh7.md`
- [Microsoft: Use WinGet](https://learn.microsoft.com/windows/package-manager/winget/)
- [Microsoft: Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)
