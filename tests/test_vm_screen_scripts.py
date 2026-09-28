"""Regression coverage for host-side screen capture and virtual keyboard input (KB/0031)."""

from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SHOT = (REPO / "scripts" / "Get-VmScreenshot.ps1").read_text(encoding="utf-8")
KEYS = (REPO / "scripts" / "Send-VmKeys.ps1").read_text(encoding="utf-8")


def test_screenshot_reaches_l2_through_powershell_direct_with_credential():
    # PowerShell Direct without -Credential hangs silently (KB/0016)
    assert "Invoke-Command -VMName $L1 -Credential $cred -ScriptBlock $capture" in SHOT


def test_screenshot_wakes_display_and_uses_native_resolution():
    assert "TypeKey" in SHOT and "0x10" in SHOT
    assert "Msvm_VideoHead" in SHOT and "CurrentHorizontalResolution" in SHOT


def test_screenshot_converts_rows_without_setpixel():
    assert ".SetPixel(" not in SHOT
    assert "LockBits" in SHOT and "Format16bppRgb565" in SHOT
    assert "$data.Stride" in SHOT


def test_scripts_do_not_shadow_automatic_args():
    for src in (SHOT, KEYS):
        assert "$args =" not in src


def test_keys_support_ordered_steps():
    for step in ("'ctrl-alt-del'", "'text'", "'key'", "'sleep'"):
        assert step in KEYS
    assert "TypeCtrlAltDel" in KEYS and "ReleaseKey" in KEYS
    assert "Invoke-Command -VMName $L1 -Credential $cred -ScriptBlock $send" in KEYS
