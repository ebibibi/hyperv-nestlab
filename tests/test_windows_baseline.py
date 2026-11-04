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
    assert "--installer-type wix" in tasks
    assert "--scope machine" in tasks
    assert "--accept-source-agreements --accept-package-agreements" in tasks
    install_line = next(
        line for line in tasks.splitlines() if "install --id Microsoft.PowerShell" in line
    )
    assert "--version" not in install_line
    assert "Get-Command winget.exe" in tasks
    assert "Install-Module -Name Microsoft.WinGet.Client" in tasks
    assert "Repair-WinGetPackageManager -AllUsers" in tasks
    assert "Prepare WinGet for the current remote user" in tasks
    assert "when: powershell_prepare.result.needs_install | bool" in tasks
    assert "$Ansible.Changed = $false" in tasks


def test_bootstrap_always_runs_windows_baseline():
    bootstrap = (REPO / "bootstrap.ps1").read_text(encoding="utf-8")
    assert '-Playbook "configure_windows_baseline.yml"' in bootstrap


def test_golden_builder_falls_back_to_host_bcdboot():
    script = (Path(__file__).resolve().parent.parent / "scripts" / "Build-WindowsGoldenDism.ps1").read_text(encoding="utf-8")
    image = script.index('"W:\\Windows\\System32\\bcdboot.exe"')
    host = script.index('"$env:SystemRoot\\System32\\bcdboot.exe"')
    assert image < host


def test_windows_11_evaluation_is_activated_before_updates():
    tasks = (Path(__file__).resolve().parent.parent / "ansible" / "roles" / "l2_config" / "tasks" / "main.yml").read_text(encoding="utf-8")
    assert "/ato" in tasks
    assert tasks.index("/ato") < tasks.index("win_updates")


def test_winrm_is_not_left_on_delayed_start():
    script = (Path(__file__).resolve().parent.parent / "scripts" / "Initialize-L2Access.ps1").read_text(encoding="utf-8")
    assert script.index("Enable-PSRemoting") < script.index("sc.exe config WinRM start= auto")


def test_bootstrap_runs_l2_config_for_windows_11_and_updates():
    script = (Path(__file__).resolve().parent.parent / "bootstrap.ps1").read_text(encoding="utf-8")
    gate = script[script.index("$needsL2Config = "):script.index("if ($needsL2Config)")]
    assert "windows_update" in gate and "windows_11" in gate
