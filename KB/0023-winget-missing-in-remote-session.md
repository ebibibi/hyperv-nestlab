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

1. Install the `Microsoft.WinGet.Client` module from PSGallery in machine scope.
2. Run `Repair-WinGetPackageManager -AllUsers`. Microsoft documents this sequence for
   bootstrapping the stable client where a usable WinGet registration is absent.
3. Run the normal latest-release command:

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Automation adds silent, agreement, and non-interactive flags. The `windows_baseline` Ansible role
skips all WinGet work when `pwsh.exe` is already present.

The automation also specifies `--installer-type wix --scope machine`. Current WinGet versions
prefer MSIX when both MSIX and WiX installers are available. PowerShell's MSIX can fail in a
non-interactive WinRM session with `0x80073d19` (the user was logged off), even after package
discovery and hash validation succeed. Selecting WiX still installs the same latest release, but
uses PowerShell's x64 MSI in machine scope.

Merely registering App Installer and `Microsoft.Winget.Source`, or resetting the WinRM connection
afterward, is insufficient on a guest that has never had an interactive logon; the source can
still fail with `0x8a15000f`.

## Lessons

- Staged AppX/MSIX packages and per-user registration are different states.
- Do not weaken ACLs on `C:\Program Files\WindowsApps` or execute another user's alias.
- WinGet normally depends on first interactive logon for per-user registration. Unattended server
  automation must establish the stable client independently of that logon.
- A new WinRM process alone does not repair a missing source registration.
- For unattended system baselines, select the WiX installer in machine scope; a remote network
  logon is not a durable interactive user session for MSIX deployment.
- Keep the package command simple when the requirement is the latest stable release.

## Related

- `KB/0017-run-ps1-with-pwsh7.md`
- [Microsoft: Use WinGet](https://learn.microsoft.com/windows/package-manager/winget/)
- [Microsoft: Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)
