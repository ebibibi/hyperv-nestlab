"""Regression coverage for teardown.ps1."""
from pathlib import Path

SRC = (Path(__file__).resolve().parent.parent / "teardown.ps1").read_text(encoding="utf-8")


def test_include_switch_targets_the_l0_control_switch():
    # l1.nat.switch (LabNAT) lives inside the L1; on L0 the control network is CtrlNAT
    assert "$m.l1.nat.switch" not in SRC
    assert '[string]$SwitchName = "CtrlNAT"' in SRC
    assert "$switchName = $SwitchName" in SRC
