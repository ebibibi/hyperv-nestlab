"""Regression coverage for transparent L2 double NAT and inbound management."""

from pathlib import Path


REPO = Path(__file__).resolve().parent.parent


def test_setup_l1_keeps_nat_and_publishes_management_and_kdc_ports():
    playbook = (REPO / "ansible" / "playbooks" / "setup_l1.yml").read_text(
        encoding="utf-8"
    )
    assert "New-NetNat -Name $natName" in playbook
    assert "Add-NetNatStaticMapping" in playbook
    assert "InternalPort: \"{{ vm.management.internal_port }}\"" in playbook
    assert "ExternalPort 88" in playbook
    assert "loop: [TCP, UDP]" in playbook
    assert "NAT があるとルーティングを壊すので除去" not in playbook


def test_control_kerberos_uses_the_l1_nat_uplink():
    setup = (REPO / "control-node" / "Setup-ControlKerberos.sh").read_text(
        encoding="utf-8"
    )
    assert 'kdc = m["l1"].get("management_ip", "10.20.0.20")' in setup
    assert "entries.append((kdc," in setup
    assert "managed_names" in setup
