"""resolver の検証 + 展開ロジックのテスト。

実行: cd <repo> && python -m pytest tests/ -q
依存: pytest, pyyaml, jsonschema
"""
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
import resolve  # noqa: E402

L1 = REPO / "l1" / "standard-host.yml"
FIX = Path(__file__).resolve().parent / "fixtures"


def build(l2_path):
    l1 = resolve.load_yaml(L1)
    l2 = resolve.load_yaml(l2_path)
    resolve.validate_schema(l1, "l1.schema.json", "L1")
    resolve.validate_schema(l2, "l2.schema.json", "L2")
    return resolve.resolve(l1, l2)


# ---------------- 正常系 ----------------

def test_fileserver_s2d_expands_correctly():
    m = build(REPO / "l2" / "fileserver-s2d.yml")
    names = [v["name"] for v in m["vms"]]
    assert names == ["dc01", "fs01", "fs02"]


def test_sequential_ip_allocation():
    m = build(REPO / "l2" / "fileserver-s2d.yml")
    ips = {v["name"]: v["nics"][0]["ip"] for v in m["vms"]}
    assert ips["fs01"] == "10.10.0.21"
    assert ips["fs02"] == "10.10.0.22"   # 連番採番


def test_data_disks_sugar_expands():
    m = build(REPO / "l2" / "fileserver-s2d.yml")
    fs01 = next(v for v in m["vms"] if v["name"] == "fs01")
    data = [d for d in fs01["disks"] if d["role"] == "data"]
    assert len(data) == 4 and all(d["size_gb"] == 100 for d in data)


def test_dns_autocomplete_points_to_dc():
    m = build(REPO / "l2" / "fileserver-s2d.yml")
    fs01 = next(v for v in m["vms"] if v["name"] == "fs01")
    assert fs01["nics"][0]["dns"] == "10.10.0.10"


def test_cluster_derived_from_group():
    m = build(REPO / "l2" / "fileserver-s2d.yml")
    assert len(m["clusters"]) == 1
    cl = m["clusters"][0]
    assert cl["nodes"] == ["fs01", "fs02"] and cl["s2d"] is True
    assert cl["witness"]["host"] == "dc01"   # YAML 予約語 'on' 回避の回帰ガード


def test_minimal_linux():
    m = build(REPO / "l2" / "minimal-linux.yml")
    assert [v["name"] for v in m["vms"]] == ["app01"]


def test_override_escape_hatch():
    m = build(FIX / "good-override.yml")
    fs01 = next(v for v in m["vms"] if v["name"] == "fs01")
    assert fs01["cpu"] == 16   # overrides がグループ既定を上書き


def test_applications_are_inherited_by_admin_vm():
    m = build(FIX / "good-applications.yml")
    admin01 = next(v for v in m["vms"] if v["name"] == "admin01")
    assert admin01["nics"][0]["dns"] == "10.10.0.10"
    assert admin01["disks"][0]["size_gb"] == 120
    assert admin01["applications"] == ["claude_code", "microsoft_word"]


def test_ad_forest_declares_external_dns_forwarders():
    m = build(REPO / "l2" / "ad-forest.yml")
    assert m["domain"]["dns_forwarders"] == ["1.1.1.1", "8.8.8.8"]


# ---------------- 異常系 ----------------

def test_duplicate_ip_detected():
    with pytest.raises(resolve.ConfigError, match="重複"):
        build(FIX / "bad-dup-ip.yml")


def test_ip_out_of_subnet_detected():
    with pytest.raises(resolve.ConfigError, match="サブネット"):
        build(FIX / "bad-ip-out-of-subnet.yml")


def test_schema_error_on_missing_required():
    with pytest.raises(resolve.ConfigError, match="スキーマ検証エラー"):
        build(FIX / "bad-schema.yml")


def test_schema_rejects_unknown_application(tmp_path):
    bad = tmp_path / "bad-application.yml"
    bad.write_text(
        "groups:\n"
        "  - name: app\n"
        "    count: 1\n"
        "    ip_from: 10.10.0.40\n"
        "    applications: [unknown_app]\n",
        encoding="utf-8",
    )
    with pytest.raises(resolve.ConfigError, match="スキーマ検証エラー"):
        build(bad)
