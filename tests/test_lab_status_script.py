"""Regression coverage for the machine-readable status script (scripts/Get-LabStatus.ps1).

The live Hyper-V paths need a real host; the behaviour that matters to callers
(valid JSON, model read from resolved.json, graceful degradation) is exercised
with pwsh when it is installed.
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "Get-LabStatus.ps1"
SRC = SCRIPT.read_text(encoding="utf-8")
sys.path.insert(0, str(REPO / "tools"))
import resolve  # noqa: E402

PWSH = shutil.which("pwsh")


def test_powershell_direct_uses_explicit_credential_and_timeout():
    # PowerShell Direct without -Credential hangs silently (KB/0016)
    assert "Invoke-Command -VMName $L1 -Credential $cred" in SRC
    assert "Wait-Job $job -Timeout $L2TimeoutSec" in SRC


def test_script_is_read_only():
    for verb in ("Start-VM", "Stop-VM", "Remove-VM", "New-VM", "Set-VM", "Remove-Item", "Restart-VM"):
        assert verb not in SRC


def test_script_does_not_shadow_automatic_args():
    assert "$args =" not in SRC


def run_status(tmp_path, model=None):
    model_path = tmp_path / "resolved.json"
    if model is not None:
        model_path.write_text(json.dumps(model), encoding="utf-8")
    out = subprocess.run(
        [PWSH, "-NoProfile", "-File", str(SCRIPT), "-ModelPath", str(model_path), "-IncludeL2"],
        capture_output=True, text=True, encoding="utf-8", timeout=120, check=True,
    )
    return json.loads(out.stdout)


@pytest.mark.skipif(not PWSH, reason="pwsh not installed")
def test_reports_not_built_without_failing(tmp_path):
    doc = run_status(tmp_path)
    assert doc["schema"] == 1
    assert doc["built"] is False
    assert doc["model"] is None
    assert [v["layer"] for v in doc["vms"]] == ["control"]


@pytest.mark.skipif(not PWSH, reason="pwsh not installed")
def test_reports_declared_model_and_unknown_l2_without_hyperv(tmp_path):
    l1 = resolve.load_yaml(REPO / "l1" / "standard-host.yml")
    l2 = resolve.load_yaml(REPO / "l2" / "ad-forest.yml")
    model = resolve.resolve(l1, l2)
    doc = run_status(tmp_path, model)

    assert doc["built"] is True
    assert doc["model"]["l1"] == "nested-lab-01"
    assert doc["model"]["domain"] == "corp.contoso.local"
    l2 = [v for v in doc["vms"] if v["layer"] == "l2"]
    assert [v["name"] for v in l2] == doc["model"]["l2"]
    dc = next(v for v in l2 if v["name"] == "dc01")
    assert dc["ip"] == "10.10.0.10"
    if not doc["host"]["hyperv"]:
        # No Hyper-V here: L2 state is unknown, never guessed
        assert all(v["state"] == "Unknown" and v["exists"] is None for v in l2)
        assert doc["l2_queried"] is False
        assert doc["errors"]
