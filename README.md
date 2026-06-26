# hyperv-nestlab

**宣言的・冪等な Nested Hyper-V ラボ構築基盤。**
既存の Hyper-V サーバー 1 台さえあれば、`bootstrap.ps1` ひとつで制御 VM (Ansible 内蔵) を
自己構築し、YAML 宣言から Nested ホスト (L1) とその中の VM 群 (L2: Windows / Linux /
Active Directory ドメイン / クラスタ) を、どこでも同じ形で再現します。

> 設計の全体像は [`plan.md`](plan.md)、宣言設定の文法は [`schema.md`](schema.md)、
> 作業メモ・ハマりどころは [`CLAUDE.md`](CLAUDE.md) を参照。

---

## 3 つの絶対基準

1. **前提は「Hyper-V サーバーがあること」だけ。** 制御環境・ツールはすべて自己ブートストラップ
   (制御 VM、Ansible、qemu-img、cloud-init シード、golden イメージは DISM 標準ツールで生成。
   Packer/ADK/oscdimg などの外部依存を持たない)。
2. **どの環境でも決定論的に同じ環境になる。** 版固定 (`assets/images.yml`) + SHA256 検証 +
   ベンダリング + 単一の宣言ファイル。再実行は冪等収束 (2 回流して no-change が受け入れ条件)。
3. **誰でも使い回せる。** 単一エントリ `bootstrap.ps1`、ハードコードされたパス/名前なし、
   データはリポジトリ配下に自己完結 (`data/`)、本ドキュメント同梱。

---

## アーキテクチャ (3 層)

```
L0  物理 Hyper-V ホスト  ── あなたが用意する唯一の前提
│
├─ 制御 VM (Ubuntu + Ansible)            CtrlNAT 10.20.0.10   ← bootstrap が自己構築
│
└─ L1: Nested Hyper-V ホスト VM           CtrlNAT 10.20.0.20
     │   (静的メモリ / ExposeVirtualizationExtensions / MACスプーフィング)
     │   ラボストア L:  ← golden / L2 VM / cloud-init シードを集約 (大容量・差分の置き場)
     │
     └─ LabNAT 10.10.0.0/24  (L1内NAT自己完結 — L2 は L1 の中で閉じる)
          ├─ L2: Windows Server 2025   (golden の差分ディスクから一瞬で作成)
          ├─ L2: Ubuntu 24.04          (cloud image の差分 + cloud-init NoCloud シード)
          ├─ L2: dc01 (AD フォレスト)   ← 新規フォレストに昇格
          └─ L2: mem01 …               ← ドメイン参加
```

### 役割分担 — PowerShell / PowerShell Direct と Ansible のハイブリッド

「Ansible 一本」ではなく、**3 つの道具を使い分ける**。分担の境界は **「対象に IP + WinRM がもう在るか」**:
それが整うまで（と L0 操作）は PowerShell、整った後の“内側の定常構成”だけ Ansible が宣言的に仕上げる。

| 層・操作 | 実行主体 | 接続方式 |
|---|---|---|
| **L0 操作** (NAT / L1作成 / 制御VM / golden配送 / ラボストア / 削除) | ホスト **PowerShell** (Hyper-V cmdlet) | ローカル |
| **“ネットワーク前”ブートストラップ** (L1/L2 の 静的IP・WinRM有効化・改名・日本語キーボード・RDP / AD 昇格・参加) | ホスト **PowerShell Direct** | (二段) PowerShell Direct (VMBus, L0→L1→L2) |
| **IP+WinRM 後の L1/L2 内部** (Hyper-V役割+LabNAT=`setup_l1` / L2作成=`create_l2` / クラスタ+S2D=`create_cluster`) | **Ansible** | 制御VM → WinRM → L1/L2 |

> **なぜ混在するか**: Ansible は IP+WinRM が前提なので、それが無い“作りたて/壊れた”段階や L0 の操作には
> 使えない。そこを **PowerShell Direct (VMBus)** が埋める（物理ネットワーク非依存で、再起動をまたぐ再接続も
> 確実 — 原則①）。AD 昇格は DC への二段ホップを伴うため PowerShell Direct。L2 は LabNAT 内に隔離され
> 制御VMから直接届かないため、いずれも L1 を踏み台にする (Windows=二段 PS Direct / Linux=L1 から SSH)。

> **構築後、どの VM にどう入るか**（SSH / WinRM / Hyper-V マネージャー / PowerShell Direct の
> 使い分け、接続マトリクス、トポロジ図）は [`docs/access-guide.md`](docs/access-guide.md) を参照。
> `bootstrap.ps1` 完了時にも実環境の値で接続サマリ (`Write-ConnectionInfo`) が表示される。

---

## クイックスタート

### 前提
- **実行は PowerShell 7 (`pwsh`) を推奨。** 本リポジトリの `.ps1` は UTF-8 (BOM なし) + 日本語コメント/文字列を
  含む。Windows PowerShell 5.1 は BOM なしスクリプトを ANSI コードページ (日本語環境=cp932) として読むため、
  日本語が化けて**構文エラーで落ちる**ことがある (例: `teardown.ps1`)。pwsh 7 は `.ps1` を既定で UTF-8 として
  読むので、そのまま正しく動く。ホストに pwsh が無ければ `winget install Microsoft.PowerShell` 等で導入する。
  （※ 全 `.ps1` を **UTF-8 with BOM** で保存し直せば 5.1 でも動くが、本プロジェクトは **pwsh 7 前提で統一**する。
  詳細は [`KB/0017`](KB/0017-run-ps1-with-pwsh7.md)。）
- Windows Server / Windows 11 等で **Hyper-V 役割が有効**であること (これだけ)。
- Python (pyyaml + jsonschema) … 設定の検証/解決に使用。
- イメージ(Windows Server 2025 評価版 ISO / Ubuntu cloud image)は **すべて自動ダウンロード**。
  Windows ISO はフォーム登録なしの固定直リンクから取得するため、利用者の手作業は不要。
  別言語/別版にしたい場合のみ `assets/images.yml` の `iso_url` を差し替える。

### 実行
> **PowerShell 7 (`pwsh`) で実行すること** (上記「前提」参照)。下記は pwsh セッション内、または
> `pwsh -File .\bootstrap.ps1 ...` の形で。SSH 越しに叩く場合も `pwsh -NoProfile -File ...` を使う。

```powershell
# まず DryRun で構築プランと必要イメージだけ確認 (VM は作らない)
.\bootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\minimal-windows.yml -DryRun

# 本番実行 (制御VM自己構築 → L1 → L2 → (あれば)AD まで一括・冪等)
.\bootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\ad-forest.yml
```

`bootstrap.ps1` の流れ:
1. プリフライト (Hyper-V / Python / 設定ファイル)
2. 検証 + 解決 (`tools/resolve.py` → `build/resolved.json`)
3. イメージ整備 (Ubuntu 自動取得 / Windows golden を DISM で生成)
4. L0→L1 プロビジョニング → ホスト WinRM → 制御 VM 構築 → ラボストア増設 → golden 配送
5. L1 内 Hyper-V+LabNAT (Ansible) → L2 作成 (Ansible) → AD 構築 (PowerShell Direct)

再実行すれば全工程が冪等に収束します (no-change が受け入れ条件)。
完了時に**フェーズ別の構築時間**と合計を表示します。

### 環境の削除 (やり直し)
```powershell
# L1 + 中の L2 すべて + 制御 VM を削除 (確認あり)。L2 は L1 のディスクごと消える
.\teardown.ps1

# 確認なしで削除 / CtrlNAT スイッチや build 成果物まで消す完全クリーン
.\teardown.ps1 -Force
.\teardown.ps1 -IncludeSwitch -IncludeBuild -Force
```
削除後に `bootstrap.ps1` を実行すれば、まっさらから再構築できます。

完了すると、建った環境への接続先・資格情報・接続例が一覧表示されます
(`Write-ConnectionInfo`)。各 VM への入り方の詳細・図解は
[`docs/access-guide.md`](docs/access-guide.md) を参照。

---

## 宣言ファイル (L1 / L2 を分離)

L1 (ホスト土台) と L2 (中身) を別ファイルにし、L1 は使い回します。スキーマ詳細は
[`schema.md`](schema.md) を参照。パターン C (ハイブリッド: 既定 + count/ip_from の糖衣 +
overrides エスケープハッチ)。

### サンプル
| ファイル | 内容 | 状態 |
|---|---|---|
| `l1/standard-host.yml` | 標準 Nested ホスト (8vCPU/32GB, LabNAT 10.10.0.0/24) | ✅ |
| `l2/minimal-windows.yml` | Windows Server 2025 を 1 台 | ✅ 実機検証 |
| `l2/minimal-linux.yml` | Ubuntu 24.04 を 1 台 (cloud-init) | ✅ 実機検証 |
| `l2/ad-forest.yml` | AD フォレスト dc01 + メンバ mem01 | ✅ 実機検証 |
| `l2/multi-lang.yml` | ゲスト言語選択のデモ (en / ja の Win + ja の Linux) | ✅ resolve/DryRun |
| `l2/fileserver-s2d.yml` | AD + 2ノード ファイルサーバクラスタ + S2D | 🚧 ロール足場 |

最小の例 (`l2/minimal-windows.yml`):
```yaml
defaults: { cpu: 2, memory_gb: 4, os: windows_server_2025 }
groups:
  - { name: win, name_prefix: win, count: 1, ip_from: 10.10.0.51 }
```

### ゲスト(L2)の言語選択
L2 ごとに `language:` を指定するだけで、その言語の ISO を自動 DL し、その言語の golden を
作って起動する (`defaults` / `group` / `vm` / `overrides` で継承・上書き可)。
```yaml
groups:
  - { name: win-ja, count: 1, ip_from: 10.10.0.62, os: windows_server_2025, language: ja-jp }
  - { name: lin-ja, count: 1, ip_from: 10.10.0.63, os: ubuntu_2404,        language: ja-jp }
```
- **Windows**: `language` の ISO を取得し言語別 golden (`win2025-golden-<lang>.vhdx`) を生成。
- **Linux**: 単一 cloud image を使い cloud-init で `locale`(例 `ja_JP.UTF-8`)を設定。
- 利用可能言語は [`assets/images.yml`](assets/images.yml) の `windows_languages.catalog`
  (en-us / ja-jp / de-de / fr-fr / es-es / it-it / ko-kr / zh-cn / pt-br / ru-ru。LCID追加で拡張可)。
- **L1(ホスト/1段目)は安定性のため常に en-us 固定**(多言語化による不具合・複雑化を避けるため)。
  将来 GUI を付ける際は、この `language` 値をチェックボックス/ドロップダウンで選ぶ形にできる。

---

## 主要コンポーネント
| パス | 役割 |
|---|---|
| `bootstrap.ps1` | 単一エントリポイント |
| `tools/resolve.py` | L1+L2 宣言の検証 (JSON Schema + 意味検証) と確定モデルへの展開 |
| `schema/*.schema.json` | L1/L2 の JSON Schema |
| `scripts/Build-WindowsGoldenDism.ps1` | ISO から golden VHDX を DISM 生成 (oscdimg 不要) |
| `scripts/Get-UbuntuImage.ps1` | Ubuntu cloud image を版固定取得 → VHDX 変換 |
| `scripts/Invoke-HostProvision.ps1` | L0 上に L1 VM を冪等作成 |
| `scripts/Add-L1LabStore.ps1` | L1 に大容量ラボストア(L:)を増設・初期化 |
| `scripts/Copy-GoldenToL1.ps1` | golden/ベースを L1 へ Copy-VMFile 配送 |
| `scripts/Publish-L2Seeds.ps1` | Linux L2 の cloud-init シードを生成・配送 |
| `scripts/Initialize-AdForest.ps1` | L2 上に AD フォレスト構築 + ドメイン参加 |
| `control-node/Ensure-ControlNode.ps1` | Ansible 内蔵 制御 VM を構築 |
| `control-node/Invoke-Ansible.ps1` | 制御 VM へ同期し playbook 実行 |
| `ansible/` | 動的インベントリ + ロール (nested_host / l1_network / l2_vm / ad / cluster_s2d / azure_local) |

---

## 開発・検証
```powershell
python -m pytest tests/ -q                 # resolver / スキーマのユニットテスト
python tools/resolve.py --l1 l1/standard-host.yml --l2 l2/ad-forest.yml --validate-only
```

---

## 設計上の要点・既知のハマりどころ
- **L2 OS ディスクは差分(ディファレンシング)ディスク**で golden/cloud image から作成。
  一瞬で済み容量も最小 (Windows L2 は初期 ~300MB)。
- **golden/L2 は L1 の OS ディスクではなくラボストア(L:)** に置く (OS ディスクは golden 由来で小さいため)。
- `ansible.windows.win_powershell` の引数は文字列で渡るため、数値は必ず `[int]` 等で型付け
  (`"4"*1GB` が文字列反復になり OutOfMemoryException になる)。
- 統合コンポーネント名はロケール依存のため ID で特定 (日本語ホスト対応)。
- group_vars は動的インベントリ隣接 (`ansible/inventory/group_vars/`) に置く。

---

## ステータス
- ✅ スキーマ / resolver / 検証 / DryRun プラン (pytest)
- ✅ L0→L1 冪等プロビジョニング (nested / 静的メモリ / MAC spoof)
- ✅ イメージ整備 (Windows=ISO直リンク自動DL→DISM golden / Ubuntu=固定URL自動DL+変換)
- ✅ 制御ノード自動構築 + 本線疎通 (制御VM Ansible → WinRM → Hyper-V)
- ✅ **L2: Windows Server 2025** (差分ディスク・冪等・実機検証)
- ✅ **L2: Ubuntu 24.04** (cloud-init で hostname/静的IP/SSH・実機検証)
- ✅ **L2: AD フォレスト + ドメイン参加** (L1踏み台 PowerShell Direct・実機検証)
- ✅ **bootstrap.ps1 一発再現** (L1→L2→AD を一括・冪等)
- 🚧 クラスタ + S2D (ロール足場) / Azure Local (別管理ロールで OSS ラップ) / GUI

進捗の詳細は [`plan.md`](plan.md) を参照。
