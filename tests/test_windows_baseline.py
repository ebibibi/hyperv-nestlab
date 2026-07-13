"""Regression coverage for the PowerShell-on-every-Windows baseline."""

from pathlib import Path


REPO = Path(__file__).resolve().parent.parent


def test_baseline_targets_every_windows_inventory_group():
    playbook = (REPO / "ansible/playbooks/configure_windows_baseline.yml").read_text(
        encoding="utf-8"
    )
    assert "hosts: l0:l1:l2_windows" in playbook
    assert "role: windows_baseline" in playbook


def test_powershell_is_installed_with_latest_winget_package():
    tasks = (REPO / "ansible/roles/windows_baseline/tasks/main.yml").read_text(
        encoding="utf-8"
    )
    assert "install --id Microsoft.PowerShell --source winget" in tasks
    assert "--accept-source-agreements --accept-package-agreements" in tasks
    install_line = next(
        line for line in tasks.splitlines() if "install --id Microsoft.PowerShell" in line
    )
    assert "--version" not in install_line
    assert "Get-Command winget.exe" in tasks
    assert "Add-AppxPackage -RegisterByFamilyName" in tasks
    assert "Microsoft.Winget.Source" in tasks
    assert "Prepare WinGet for the current remote user" in tasks
    assert "when: powershell_prepare.result.needs_install | bool" in tasks
    assert "WinGet must run in the next Ansible task" in tasks
    assert "$Ansible.Changed = $false" in tasks


def test_bootstrap_always_runs_windows_baseline():
    bootstrap = (REPO / "bootstrap.ps1").read_text(encoding="utf-8")
    assert '-Playbook "configure_windows_baseline.yml"' in bootstrap
