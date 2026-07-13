"""Regression coverage for declarative L1 OS disk expansion."""

from pathlib import Path


REPO = Path(__file__).resolve().parent.parent


def test_host_provision_expands_cloned_and_existing_vhdx_without_shrinking():
    module = (REPO / "scripts" / "HyperVLab.psm1.ps1").read_text(
        encoding="utf-8"
    )
    assert "$desiredDiskBytes = [int64]$DiskGB * 1GB" in module
    assert "if ($vhd.Size -lt $desiredDiskBytes)" in module
    assert "Resize-VHD -Path $osDrive.Path -SizeBytes $desiredDiskBytes" in module
    assert "Resize-VHD" not in module.split("if ($vhd.Size -lt $desiredDiskBytes)", 1)[0]


def test_l1_bootstrap_extends_c_partition_idempotently():
    script = (REPO / "scripts" / "Initialize-L1Network.ps1").read_text(
        encoding="utf-8"
    )
    assert "Get-PartitionSupportedSize -DriveLetter C" in script
    assert "($supported.SizeMax - $partition.Size) -gt 64MB" in script
    assert "Resize-Partition -DriveLetter C -Size $supported.SizeMax" in script


def test_standard_l1_disk_has_operational_headroom():
    declaration = (REPO / "l1" / "standard-host.yml").read_text(encoding="utf-8")
    assert "disk_gb: 160" in declaration
