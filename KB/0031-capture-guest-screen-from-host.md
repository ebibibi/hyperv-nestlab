# 0031 — Capturing an L2 guest's screen from the host returns black / needs L2 reach

## Symptom

We wanted screenshots of Windows L2 GUIs (sign-in screen, Event Viewer, Server Manager) for verification
records and explainer videos, without installing anything in the guest. Three problems showed up:

- `GetVirtualSystemThumbnailImage` on an L2 VM that had been idle for days returned an **all-black** frame
  (`rc=0`, 1.8 MB of image data, only 3 non-zero bytes).
- The old `scripts/Get-VmScreenshot.ps1` looked the VM up on the local host only, so it could not see L2 VMs
  (they live inside the L1's Hyper-V, not L0's).
- Converting RGB565 with `Bitmap.SetPixel` per pixel was far too slow for full-resolution frames.

## Cause

- The guest had turned its display off (power settings). The synthetic video device then presents a black
  frame; the call itself succeeds, so nothing looks wrong.
- The WMI provider (`root\virtualization\v2`) is per Hyper-V host. An L2's `Msvm_ComputerSystem` only exists
  inside the L1.
- `SetPixel` is a managed call per pixel (786k calls for 1024x768).

## Fix

`scripts/Get-VmScreenshot.ps1` (rewritten) and `scripts/Send-VmKeys.ps1` (new):

- `-L1 <name>` runs the capture inside the L1 over PowerShell Direct and returns only the PNG bytes to L0.
- `-Wake` taps Shift through `Msvm_Keyboard.TypeKey` and waits 2 s before capturing.
- Width/height default to the guest's current resolution from `Msvm_VideoHead`, so nothing is rescaled.
- The RGB565 buffer is copied row by row into a `Format16bppRgb565` bitmap with `LockBits` +
  `Marshal.Copy` (the bitmap stride is padded to 4 bytes, the thumbnail rows are not).
- `Send-VmKeys.ps1` drives `Msvm_Keyboard` (`TypeCtrlAltDel`, `TypeText`, `PressKey`/`TypeKey`/`ReleaseKey`)
  with ordered steps: `ctrl-alt-del`, `text:...`, `key:Win+R`, `sleep:ms`.

Measured on nested-lab-01 → srv01 (1024x768):

| Operation | Time |
|---|---|
| One capture incl. PowerShell Direct session and `-Wake` | ~5 s |
| Burst (`-Count 10`) | ~290 ms per frame (≈3.4 fps) |

`TypeText` with `P@ssw0rd-Lab-Change!` signed in correctly on a guest with the Japanese keyboard layer
(KB/0015). Still check symbols once per new guest language before relying on it.

## Lessons / general know-how

- A successful thumbnail call does not mean a meaningful image: wake the display first, and treat a
  near-zero buffer as "display off", not as a failure of the capture path.
- Host-side capture + virtual keyboard is a zero-footprint way to drive and record any guest, including the
  lock screen and machines without network. It is slow (a few fps), so use it for stills and step-by-step
  sequences; record smooth motion inside the guest instead.
- Everything in nested labs that uses Hyper-V WMI must run on the host that owns the VM (L0 for L1, L1 for L2).
