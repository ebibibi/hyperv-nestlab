"""Static regressions for the PowerShell AD forest convergence script."""

from pathlib import Path


REPO = Path(__file__).resolve().parent.parent


def test_dns_forwarder_comparison_handles_an_empty_current_list():
    script = (REPO / "scripts" / "Initialize-AdForest.ps1").read_text(
        encoding="utf-8"
    )
    assert "$currentKey = (($current | Sort-Object) -join ',')" in script
    assert "$wantedKey = (($wanted | Sort-Object) -join ',')" in script
    assert "if ($currentKey -ne $wantedKey)" in script
    assert "Compare-Object ($current | Sort-Object)" not in script
