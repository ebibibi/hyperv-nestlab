#!/usr/bin/env python3
"""
動的インベントリ: build/resolved.json を読んで Ansible のグループ/ホスト変数に変換する。

グループ:
  l0                : 物理 Hyper-V ホスト (環境変数 HYPERV_HOST で指定)
  l1                : Nested Hyper-V ホスト VM
  l2_windows / l2_linux : L2 VM (OS で分類)
  domain_controllers    : DC
  cluster_nodes         : クラスタ参加ノード

各ホストの hostvars には確定モデルの VM スペックがそのまま入る。
"""
import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MODEL = Path(os.environ.get("RESOLVED_MODEL", REPO / "build" / "resolved.json"))


def empty():
    return {"hosts": [], "vars": {}}


def main():
    if "--host" in sys.argv:
        print(json.dumps({}))
        return 0

    if not MODEL.is_file():
        sys.exit(f"resolved model がありません: {MODEL} (先に bootstrap で生成してください)")

    model = json.loads(MODEL.read_text(encoding="utf-8"))
    inv = {"_meta": {"hostvars": {}}}
    inv["l0"] = empty()
    inv["l1"] = empty()
    inv["l2_windows"] = empty()
    inv["l2_linux"] = empty()
    inv["domain_controllers"] = empty()
    inv["cluster_nodes"] = empty()

    # L0 物理ホスト。制御 VM から見たホスト IP は CtrlNAT ゲートウェイ (既定 10.20.0.1)。
    l0_host = os.environ.get("HYPERV_HOST", "hyperv-host")
    l0_addr = os.environ.get("HYPERV_ADDR", "10.20.0.1")
    inv["l0"]["hosts"].append(l0_host)
    l0_vars = {
        "ansible_host": l0_addr,
        "ansible_connection": "winrm",
        "ansible_port": int(os.environ.get("HYPERV_WINRM_PORT", "5985")),
        "ansible_winrm_transport": "ntlm",
        "ansible_winrm_scheme": "http",
        "ansible_winrm_server_cert_validation": "ignore",
        "l1": model["l1"],
    }
    # 資格情報は環境変数優先 (疎通検証用)。本番は vault から group_vars 経由。
    if os.environ.get("HYPERV_USER"):
        l0_vars["ansible_user"] = os.environ["HYPERV_USER"]
    if os.environ.get("HYPERV_PASSWORD"):
        l0_vars["ansible_password"] = os.environ["HYPERV_PASSWORD"]
    inv["_meta"]["hostvars"][l0_host] = l0_vars

    # L1 Nested ホスト
    l1name = model["l1"]["name"]
    inv["l1"]["hosts"].append(l1name)
    inv["_meta"]["hostvars"][l1name] = {"l1": model["l1"]}

    # L2 VM
    clusters = {c["name"]: c for c in model.get("clusters", [])}
    cluster_members = {n for c in model.get("clusters", []) for n in c["nodes"]}

    for vm in model.get("vms", []):
        name = vm["name"]
        os_name = (vm.get("os") or "").lower()
        grp = "l2_linux" if any(k in os_name for k in ("ubuntu", "debian", "linux", "rocky", "alma")) else "l2_windows"
        inv[grp]["hosts"].append(name)
        hv = dict(vm)
        if vm.get("provision", {}).get("forest"):
            inv["domain_controllers"]["hosts"].append(name)
        if name in cluster_members:
            inv["cluster_nodes"]["hosts"].append(name)
            hv["cluster"] = next((c for c in clusters.values() if name in c["nodes"]), None)
        inv["_meta"]["hostvars"][name] = hv

    inv["all"] = {"children": ["l0", "l1", "l2_windows", "l2_linux"]}
    inv["all"]["vars"] = {"domain": model.get("domain"), "clusters": model.get("clusters", [])}

    print(json.dumps(inv, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
