#!/usr/bin/env python3
"""
resolve.py - Nested Hyper-V 宣言設定の検証 + 展開エンジン (resolver)

L1 ファイルと L2 ファイルを読み、
  1. JSON Schema で構文検証 (fail-fast)
  2. 継承 (L1.l2_defaults < L2.defaults < group < overrides) を適用
  3. count / ip_from の連番、data_disks 糖衣、DNS 自動補完を展開
  4. 意味検証 (IP のサブネット内判定 / 名前重複 / IP 重複 / クラスタ整合)
して、フラットな「確定モデル」を JSON で出力する。

このスクリプトは制御 VM 内 (Ansible の入力生成) でも、
ホスト上の bootstrap.ps1 -DryRun でも同一ロジックとして使われる。

依存: pyyaml, jsonschema (いずれも標準的なラボイメージ / 本リポジトリ前提に同梱)

使い方:
  python resolve.py --l1 l1/standard-host.yml --l2 l2/fileserver-s2d.yml
  python resolve.py --l1 ... --l2 ... --validate-only
  python resolve.py --l1 ... --l2 ... --out build/resolved.json
"""
import argparse
import copy
import ipaddress
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("ERROR: pyyaml がありません。'pip install pyyaml' を実行してください。")
try:
    import jsonschema
except ImportError:
    sys.exit("ERROR: jsonschema がありません。'pip install jsonschema' を実行してください。")

REPO = Path(__file__).resolve().parent.parent
SCHEMA_DIR = REPO / "schema"

# 既定値
DEFAULT_OS_DISK_GB = 80
# language も継承対象 (L1.l2_defaults < L2.defaults < group < overrides)
INHERITABLE = (
    "cpu", "memory_gb", "os", "generation", "domain_join", "disk_gb",
    "language", "features", "applications",
)

LINUX_RE = re.compile(r"ubuntu|debian|linux|rocky|alma", re.I)


def is_linux_os(os_name):
    return bool(LINUX_RE.search(os_name or ""))


def load_images_catalog():
    """assets/images.yml を読み、言語カタログ等を返す (無ければ空)。"""
    p = REPO / "assets" / "images.yml"
    if not p.is_file():
        return {}
    try:
        return yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError:
        return {}


class ConfigError(Exception):
    pass


def load_yaml(path):
    p = Path(path)
    if not p.is_file():
        raise ConfigError(f"ファイルが見つかりません: {path}")
    try:
        with p.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        raise ConfigError(f"YAML パースに失敗しました ({path}): {e}")
    if not isinstance(data, dict):
        raise ConfigError(f"トップレベルはマップである必要があります: {path}")
    return data


def load_schema(name):
    return json.loads((SCHEMA_DIR / name).read_text(encoding="utf-8"))


def validate_schema(data, schema_name, label):
    schema = load_schema(schema_name)
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
    if errors:
        msgs = []
        for e in errors:
            loc = "/".join(str(x) for x in e.path) or "(root)"
            msgs.append(f"  [{label}] {loc}: {e.message}")
        raise ConfigError("スキーマ検証エラー:\n" + "\n".join(msgs))


def deep_merge(base, over):
    """over を base に深いマージ。リストは置換 (より具体的な層が丸ごと上書き)。"""
    result = copy.deepcopy(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(result.get(k), dict):
            result[k] = deep_merge(result[k], v)
        else:
            result[k] = copy.deepcopy(v)
    return result


def pick(d, keys):
    return {k: d[k] for k in keys if k in d}


def make_disks(spec, data_disks):
    disks = [{"role": "os", "size_gb": spec.get("disk_gb", DEFAULT_OS_DISK_GB)}]
    if data_disks:
        for _ in range(data_disks["count"]):
            disks.append({"role": "data", "size_gb": data_disks["size_gb"]})
    return disks


def resolve(l1, l2):
    l1h = l1["l1_host"]
    nat = l1h["network"]["nat"]
    switch = nat["switch"]
    gw = nat["host_ip"]
    subnet = ipaddress.ip_network(nat["subnet"], strict=False)

    # 言語カタログ (L2 ゲストの言語選択用)。L1 は常に en-us 固定。
    imgcat = load_images_catalog()
    wl = imgcat.get("windows_languages", {}) or {}
    win_catalog = wl.get("catalog", {}) or {}
    default_lang = wl.get("default", "en-us")
    fwlink = wl.get("fwlink", "https://go.microsoft.com/fwlink/?linkid=2345828&clcid={clcid}&culture={culture}&country={country}")
    win_img = (imgcat.get("images", {}) or {}).get("win2025-golden", {}) or {}
    golden_pattern = win_img.get("golden_pattern", "win2025-golden-{lang}.vhdx")
    iso_pattern = win_img.get("iso_pattern", "windows-server-2025-{lang}.iso")
    linux_locales = imgcat.get("linux_locales", {}) or {}
    ubuntu_basename = "ubuntu2404-cloudimg.vhdx"
    L1_LANG = "en-us"   # ホスト(1段目)は安定性のため英語固定

    base = deep_merge(l1h.get("l2_defaults", {}), l2.get("defaults", {}))

    domain = l2.get("domain")
    dns_default = None
    if domain and domain.get("controllers"):
        dns_default = domain["controllers"][0]["ip"]

    vms = []
    clusters = []

    # --- ドメインコントローラ ---
    if domain:
        for c in domain.get("controllers", []):
            spec = deep_merge(base, pick(c, ("cpu", "memory_gb", "os")))
            spec["name"] = c["name"]
            spec["disks"] = make_disks(spec, None)
            spec["nics"] = [{"switch": switch, "ip": c["ip"], "gw": gw, "dns": "127.0.0.1"}]
            spec["domain_join"] = False
            spec["provision"] = {
                "roles": ["AD-Domain-Services", "DNS"],
                "forest": {
                    "fqdn": domain["fqdn"],
                    "netbios": domain.get("netbios"),
                    "dsrm_password": domain.get("dsrm_password"),
                },
            }
            vms.append(spec)

    # --- グループ展開 ---
    for g in l2.get("groups", []):
        prefix = g.get("name_prefix", g["name"])
        start = g.get("index_start", 1)
        width = g.get("index_width", 2)
        ip_from = ipaddress.ip_address(g["ip_from"])
        data_disks = g.get("data_disks")
        roles = g.get("roles", [])
        cluster = g.get("cluster")
        overrides = g.get("overrides", {})
        group_settings = pick(g, INHERITABLE)

        node_names = []
        for j in range(g["count"]):
            idx = start + j
            name = f"{prefix}{idx:0{width}d}"
            node_names.append(name)
            ip = str(ip_from + j)

            spec = deep_merge(base, group_settings)
            spec["name"] = name
            spec["disks"] = make_disks(spec, data_disks)
            dns = dns_default if spec.get("domain_join") else None
            nic = {"switch": switch, "ip": ip, "gw": gw}
            if dns:
                nic["dns"] = dns
            spec["nics"] = [nic]
            prov = {"roles": list(roles)}
            if cluster:
                prov["member_of"] = cluster["name"]
            spec["provision"] = prov

            # VM 個別の低レベル上書き (エスケープハッチ)
            if name in overrides:
                spec = deep_merge(spec, overrides[name])
            vms.append(spec)

        if cluster:
            clusters.append({
                "name": cluster["name"],
                "ip": cluster["ip"],
                "nodes": node_names,
                "s2d": cluster.get("s2d", False),
                "witness": cluster.get("witness"),
                "roles": [cluster["role"]] if cluster.get("role") else [],
            })

    # --- 明示 VM (パターン A) ---
    for v in l2.get("vms", []):
        spec = deep_merge(base, v)
        # nics の switch 未指定なら NAT スイッチを補完
        for nic in spec.get("nics", []):
            nic.setdefault("switch", switch)
            nic.setdefault("gw", gw)
        vms.append(spec)

    # --- 明示クラスタ (パターン A) ---
    for c in l2.get("clusters", []):
        clusters.append({
            "name": c["name"],
            "ip": c["ip"],
            "nodes": c["nodes"],
            "s2d": (c.get("storage", {}).get("s2d", {}) or {}).get("enabled", False),
            "witness": c.get("witness"),
            "roles": c.get("roles", []),
        })

    # --- 言語 / ベースイメージファイル / ロケールを各 VM に付与 ---
    # language は INHERITABLE なので各 spec に既に入っている場合がある。未指定は既定言語。
    for vm in vms:
        lang = vm.get("language") or default_lang
        vm["language"] = lang
        vm.setdefault("features", [])   # L2 で導入する Windows 機能 (Ansible win_feature)
        vm.setdefault("applications", [])  # L2 で導入するアプリ (Ansible l2_config)
        if is_linux_os(vm.get("os")):
            vm["base_image_file"] = ubuntu_basename
            vm["locale"] = linux_locales.get(lang, "en_US.UTF-8")
        else:
            if lang not in win_catalog:
                raise ConfigError(
                    f"VM '{vm.get('name')}' の language '{lang}' は未対応です。"
                    f"利用可能: {', '.join(sorted(win_catalog.keys()))} "
                    f"(assets/images.yml の windows_languages.catalog に追加可)"
                )
            vm["base_image_file"] = golden_pattern.format(lang=lang)

    # L1 performs the first stage of double NAT for transparent L2 internet access.
    # Give every L2 VM a deterministic inbound management port on the L1 uplink so the
    # control VM can still reach WinRM/SSH across that NAT boundary.
    for index, vm in enumerate(vms):
        vm["management"] = {
            "external_port": 15985 + index,
            "internal_port": 22 if is_linux_os(vm.get("os")) else 5985,
        }

    # --- 整備が必要なイメージ集合 (bootstrap が DL/ビルドする) ---
    needed = {}

    def add_win(lang):
        if lang not in win_catalog:
            raise ConfigError(f"language '{lang}' は未対応です。利用可能: {', '.join(sorted(win_catalog.keys()))}")
        if ("windows", lang) in needed:
            return
        c = win_catalog[lang]
        needed[("windows", lang)] = {
            "kind": "windows",
            "language": lang,
            "label": c.get("label", lang),
            "golden_file": golden_pattern.format(lang=lang),
            "iso_name": iso_pattern.format(lang=lang),
            "iso_url": fwlink.format(clcid=c["clcid"], culture=c["culture"], country=c["country"]),
        }

    add_win(L1_LANG)   # L1(ホスト)は常に en-us
    linux_needed = False
    for vm in vms:
        if is_linux_os(vm.get("os")):
            linux_needed = True
        else:
            add_win(vm.get("language") or default_lang)
    images_needed = list(needed.values())
    if linux_needed:
        images_needed.append({"kind": "linux", "vhdx": ubuntu_basename})

    model = {
        "l1": {
            "name": l1h["name"],
            "cpu": l1h["cpu"],
            "memory_gb": l1h["memory_gb"],
            "nested": l1h.get("nested", True),
            "disk_gb": l1h.get("disk_gb", 120),
            "base_image": l1h.get("base_image"),
            # L1 は英語固定 golden を使う (ホスト言語は en-us 固定)
            "base_image_file": golden_pattern.format(lang=L1_LANG),
            "language": L1_LANG,
            "l0_switch": l1h.get("l0_switch", "Default Switch"),
            "nat": {"switch": switch, "subnet": str(subnet), "host_ip": gw},
            "management_ip": "10.20.0.20",
        },
        "domain": domain,
        "vms": vms,
        "clusters": clusters,
        "images_needed": images_needed,
    }
    semantic_checks(model, subnet, gw)
    return model


def semantic_checks(model, subnet, gw):
    errors = []
    seen_names = {}
    seen_ips = {}
    gw_addr = ipaddress.ip_address(gw)

    for vm in model["vms"]:
        name = vm.get("name")
        if name in seen_names:
            errors.append(f"VM 名が重複しています: {name}")
        seen_names[name] = True
        for nic in vm.get("nics", []):
            ip = nic.get("ip")
            if not ip:
                continue
            addr = ipaddress.ip_address(ip)
            if addr not in subnet:
                errors.append(f"{name} の IP {ip} がサブネット {subnet} の外です")
            if addr == gw_addr:
                errors.append(f"{name} の IP {ip} が NAT ゲートウェイ {gw} と衝突しています")
            if ip in seen_ips:
                errors.append(f"IP が重複しています: {ip} ({seen_ips[ip]} と {name})")
            seen_ips[ip] = name

    node_set = set(seen_names)
    for cl in model["clusters"]:
        if len(cl["nodes"]) < 2:
            errors.append(f"クラスタ {cl['name']} のノードが 2 未満です")
        for n in cl["nodes"]:
            if n not in node_set:
                errors.append(f"クラスタ {cl['name']} が未定義ノード {n} を参照しています")
        ip = cl.get("ip")
        if ip:
            addr = ipaddress.ip_address(ip)
            if addr not in subnet:
                errors.append(f"クラスタ {cl['name']} の IP {ip} がサブネット {subnet} の外です")
            if ip in seen_ips:
                errors.append(f"クラスタ IP {ip} が VM {seen_ips[ip]} と衝突しています")
            seen_ips[ip] = cl["name"]
        if cl.get("s2d"):
            for n in cl["nodes"]:
                vm = next((v for v in model["vms"] if v.get("name") == n), None)
                ndata = sum(1 for d in (vm.get("disks") or []) if d.get("role") == "data") if vm else 0
                if ndata < 1:
                    errors.append(f"S2D クラスタ {cl['name']} のノード {n} に data ディスクがありません")

    if errors:
        raise ConfigError("意味検証エラー:\n" + "\n".join("  " + e for e in errors))


def main():
    ap = argparse.ArgumentParser(description="Nested Hyper-V 設定 resolver")
    ap.add_argument("--l1", required=True, help="L1 定義ファイル")
    ap.add_argument("--l2", required=True, help="L2 定義ファイル")
    ap.add_argument("--validate-only", action="store_true", help="検証のみ (展開結果を出力しない)")
    ap.add_argument("--out", help="確定モデルの出力先 (省略時は stdout)")
    args = ap.parse_args()

    try:
        l1 = load_yaml(args.l1)
        l2 = load_yaml(args.l2)
        validate_schema(l1, "l1.schema.json", "L1")
        validate_schema(l2, "l2.schema.json", "L2")
        model = resolve(l1, l2)
    except ConfigError as e:
        print(f"NG: 設定エラー\n{e}", file=sys.stderr)
        return 2

    if args.validate_only:
        print(f"OK: 検証成功  (VM {len(model['vms'])} 台 / クラスタ {len(model['clusters'])} 個)")
        return 0

    out = json.dumps(model, ensure_ascii=False, indent=2)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(out, encoding="utf-8")
        print(f"OK: 確定モデルを書き出しました -> {args.out}  (VM {len(model['vms'])} 台 / クラスタ {len(model['clusters'])} 個)")
    else:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
