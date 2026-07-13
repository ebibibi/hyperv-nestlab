"""Static regression tests for bounded control-node SSH operations."""

from pathlib import Path


REPO = Path(__file__).resolve().parent.parent


def test_readiness_probe_has_noninteractive_keepalive_limits():
    script = (REPO / "control-node" / "Ensure-ControlNode.ps1").read_text(
        encoding="utf-8"
    )
    assert '"BatchMode=yes"' in script
    assert '"ServerAliveInterval=5"' in script
    assert '"ServerAliveCountMax=3"' in script
    assert ".WaitForExit(15000)" in script
    assert ".Kill($true)" in script
    assert "$psi.RedirectStandardOutput = $false" in script
    assert "$psi.RedirectStandardError = $false" in script
    assert ".StandardOutput.ReadToEnd()" not in script
    assert '"test -s /home/labadmin/ansible-ready.txt"' in script
