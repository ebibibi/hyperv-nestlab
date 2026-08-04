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
    assert fs01["nics"][0]["dns"] == ["10.10.0.10"]


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
    assert admin01["nics"][0]["dns"] == ["10.10.0.10"]
    assert admin01["disks"][0]["size_gb"] == 120
    assert admin01["applications"] == ["claude_code", "microsoft_word"]
    assert admin01["management"] == {"external_port": 15986, "internal_port": 5985}


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


# ---------------- Azure Arc ----------------

def test_arc_demo_marks_both_guests_for_onboarding():
    """arc-demo.yml は Windows/Linux 双方を Arc 参加として展開する。"""
    m = build(REPO / "l2" / "arc-demo.yml")
    arc = {v["name"]: v["arc"] for v in m["vms"]}
    assert arc == {"arcwin01": True, "arclnx01": True}


def test_arc_connection_target_is_resolved_with_agent_defaults():
    """接続先はモデルに載り、エージェント配布 URL は既定で補完される。"""
    m = build(REPO / "l2" / "arc-demo.yml")
    assert m["azure_arc"]["resource_group"] == "rg-hccjp76-arc"
    assert m["azure_arc"]["location"] == "japaneast"
    assert m["azure_arc"]["agent"]["windows_msi_url"].startswith("https://")
    assert m["azure_arc"]["agent"]["linux_install_script_url"].startswith("https://")


def test_arc_defaults_to_false_when_not_declared():
    """arc を書かない従来の宣言は、全 VM が非参加のままで azure_arc も無い。"""
    m = build(REPO / "l2" / "minimal-windows.yml")
    assert all(v["arc"] is False for v in m["vms"])
    assert m["azure_arc"] is None


def test_arc_flag_is_inheritable_and_overridable():
    """defaults の arc はグループ/VM 個別で上書きできる。"""
    l1 = resolve.load_yaml(L1)
    l2 = {
        "azure_arc": {"resource_group": "rg-x", "location": "japaneast"},
        "defaults": {"os": "windows_server_2025", "arc": True},
        "groups": [
            {"name": "a", "count": 2, "ip_from": "10.10.0.51",
             "overrides": {"a02": {"arc": False}}},
        ],
    }
    resolve.validate_schema(l2, "l2.schema.json", "L2")
    m = resolve.resolve(l1, l2)
    assert {v["name"]: v["arc"] for v in m["vms"]} == {"a01": True, "a02": False}


def test_arc_without_connection_target_is_rejected():
    """arc: true があるのに azure_arc が無い宣言は意味検証で弾く。"""
    l1 = resolve.load_yaml(L1)
    l2 = {
        "defaults": {"os": "windows_server_2025", "arc": True},
        "groups": [{"name": "a", "count": 1, "ip_from": "10.10.0.51"}],
    }
    with pytest.raises(resolve.ConfigError, match="azure_arc"):
        resolve.resolve(l1, l2)


def test_arc_target_without_participants_is_rejected():
    """接続先だけ書いて参加 VM がゼロの宣言も弾く (書き忘れの検知)。"""
    l1 = resolve.load_yaml(L1)
    l2 = {
        "azure_arc": {"resource_group": "rg-x", "location": "japaneast"},
        "defaults": {"os": "windows_server_2025"},
        "groups": [{"name": "a", "count": 1, "ip_from": "10.10.0.51"}],
    }
    with pytest.raises(resolve.ConfigError, match="arc: true"):
        resolve.resolve(l1, l2)


# ---------------- DNS ----------------

def test_domainless_l2_gets_default_resolver_not_gateway():
    """ドメイン無しでも DNS が入る。L1 (ゲートウェイ) は DNS サーバーではないため使わない。"""
    m = build(REPO / "l2" / "arc-demo.yml")
    for vm in m["vms"]:
        assert vm["nics"][0]["dns"] == resolve.DEFAULT_L2_DNS
        assert vm["nics"][0]["dns"] != [vm["nics"][0]["gw"]]


def test_declared_dns_wins_over_dc_and_default():
    """宣言した dns は DC 自動補完より優先され、単一値でもリストに正規化される。"""
    l1 = resolve.load_yaml(L1)
    l2 = {
        "defaults": {"os": "windows_server_2025"},
        "groups": [
            {"name": "a", "count": 1, "ip_from": "10.10.0.51", "dns": "10.10.0.99"},
            {"name": "b", "count": 1, "ip_from": "10.10.0.61", "dns": ["10.10.0.98", "1.1.1.1"]},
        ],
    }
    resolve.validate_schema(l2, "l2.schema.json", "L2")
    m = resolve.resolve(l1, l2)
    dns = {v["name"]: v["nics"][0]["dns"] for v in m["vms"]}
    assert dns == {"a01": ["10.10.0.99"], "b01": ["10.10.0.98", "1.1.1.1"]}
