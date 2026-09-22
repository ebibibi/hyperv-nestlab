"""Static contracts for the reusable child-domain lab provisioner."""

from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "Add-LabChildDomainController.ps1"


def script_text() -> str:
    return SCRIPT.read_text(encoding="utf-8-sig")


def test_child_domain_uses_the_supported_adds_deployment_cmdlet():
    script = script_text()
    assert "Install-ADDSDomain" in script
    assert "-DomainType ChildDomain" in script
    assert "-ParentDomainName $ParentDomain" in script
    assert "-NewDomainNetbiosName $ChildNetBIOSName" in script
    assert '"Administrator@$ParentDomain"' in script
    assert '"$ParentNetBIOSName\\Administrator"' not in script


def test_child_domain_vm_uses_dynamic_memory():
    script = script_text()
    assert "Set-VMMemory" in script
    assert "-DynamicMemoryEnabled $true" in script
    assert "-MinimumBytes ($MinMemoryGB * 1GB)" in script
    assert "-MaximumBytes ($MemoryGB * 1GB)" in script


def test_child_domain_checks_final_state_before_using_local_credentials():
    script = script_text()
    final_state = script.index("$state = Invoke-Command")
    local_login = script.index("Waiting for local Administrator sign-in")
    assert final_state < local_login
    assert "$state.Domain -eq $ChildDomainFqdn" in script
    assert "$state.Role -in 4, 5" in script


def test_child_domain_enables_adws_and_uses_itself_as_primary_dns():
    script = script_text()
    assert "Set-Service ADWS -StartupType Automatic" in script
    assert "Start-Service ADWS" in script
    assert "-ServerAddresses @('127.0.0.1', $ParentIp)" in script
    assert "(Get-ADForest).Domains" in script
    assert "function Wait-ChildDcHealthy" in script
    assert "already a healthy controller" in script


def test_child_domain_repairs_nested_dns_and_parent_delegation():
    script = script_text()
    assert "function Repair-ChildDomainDns" in script
    assert "Add-DnsServerZoneDelegation" in script
    assert "Add-DnsServerPrimaryZone -Name $ChildZone -ReplicationScope Domain" in script
    assert '-ZoneFile "$ChildZone.dns"' in script
    assert "Add-DnsServerDirectoryPartition" in script
    assert "ConvertTo-DnsServerPrimaryZone -Name $ChildZone -ReplicationScope Domain" in script
    assert "Set-DnsServerPrimaryZone -Name $ChildZone -DynamicUpdate Secure" in script
    assert "remains file-backed" in script
    assert '"_ldap._tcp.dc._msdcs.$ChildZone"' in script


def test_child_domain_restarts_windows_gracefully():
    script = script_text()
    assert "function Restart-LabGuestGracefully" in script
    assert "Restart-Computer -Force" in script
    assert "LastBootUpTime" in script
    assert "afterBoot -gt" in script
    assert "Restart-VM -Name $Name -Force" not in script
