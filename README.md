# nestedhyper-v

既存の Hyper-V サーバー上に **Nested Hyper-V 環境をコードで定義し、冪等・決定的に構築する**基盤。

> 設計の全体像は [`plan.md`](plan.md)、宣言設定の文法は [`schema.md`](schema.md) を参照。

## 譲れない 3 原則

1. **前提は Hyper-V サーバーがあること、ただそれだけ。** 制御環境・ツールは自前でブートストラップする。
2. **どこでも一義的に同じ環境が出来上がる。** バージョン固定 + ベンダリング + オフライン耐性。
3. **誰もが使い回せる。** エントリポイントは 1 つ、設定は宣言ファイル 2 本だけ。

## 使い方

```powershell
# 1. 設定を用意 (L1 は使い回し、L2 だけ差し替える)
#    例は l1/standard-host.yml と l2/fileserver-s2d.yml

# 2. まずは DryRun で検証 + プラン + 必要イメージ確認 (VM は作られない)
.\bootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\fileserver-s2d.yml -DryRun

# 3. (Windows を使う場合のみ) Server 2025 評価版 ISO を assets\iso\ に置く
#    -> assets\iso\README.md の手順。Ubuntu は何も置かなくて OK (自動取得)。

# 4. 本番実行 (golden イメージは自動整備される)
.\bootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\fileserver-s2d.yml
```

### イメージの整備（利用者の手間は最小）

`bootstrap.ps1` が必要な golden イメージを自動で用意する（原則①）。

| OS | 利用者の操作 | スクリプトの処理 |
|---|---|---|
| **Windows** | `assets\iso\` に Server 2025 評価版 ISO を 1 つ置くだけ | Packer を自動取得し Autounattend で無人ビルド → `win2025-golden.vhdx` |
| **Ubuntu** | 何もしない | 固定 URL の cloud image (軽量・約599MB) を自動 DL + SHA256 検証 + VHDX 変換 |

固定 URL・チェックサム・版は [`assets/images.yml`](assets/images.yml) で一元管理（原則②）。

`-DryRun` は **検証 (JSON Schema + 意味検証) と解決 (確定モデル生成) のみ**を行い、作成される
VM・クラスタの一覧を表示する。安全なので最初は必ずこれで確認する。

## 設定ファイル

| ファイル | 役割 |
|---|---|
| `l1/*.yml` | Nested Hyper-V ホストの定義（使い回す土台） |
| `l2/*.yml` | 中に作る VM 群・ドメイン・クラスタ（検証ごとに差し替え） |
| `secrets.yml` | シークレット（`secrets.example.yml` をコピーして Ansible Vault で暗号化） |

L2 はパターン C（ハイブリッド）。既定値で短く書き、必要な所だけ `overrides` で低レベルまで降りられる。
最小例:

```yaml
# l2/minimal-linux.yml
defaults: { cpu: 2, memory_gb: 4, os: ubuntu_2404 }
groups:
  - name: app
    count: 1
    ip_from: 10.10.0.41
```

複雑な例（AD フォレスト + 2ノード S2D ファイルサーバ・クラスタ）は [`l2/fileserver-s2d.yml`](l2/fileserver-s2d.yml)。

## アーキテクチャ (3 層)

```
L0 物理 Hyper-V サーバー (唯一の前提)
 └─ bootstrap.ps1 が制御 VM を自動構築 → 以降は Ansible が担当
     └─ L1 Nested Hyper-V ホスト (NAT 自己完結)
         └─ L2 VM 群 (Windows / Linux / AD / クラスタ)
```

詳細は [`plan.md`](plan.md)。

## 開発・検証

```powershell
# resolver / スキーマのユニットテスト
python -m pytest tests/ -q

# 設定だけ検証 (CI 向け)
python tools/resolve.py --l1 l1/standard-host.yml --l2 l2/fileserver-s2d.yml --validate-only
```

## ディレクトリ

| パス | 内容 |
|---|---|
| `bootstrap.ps1` | 唯一のエントリポイント |
| `schema/` | JSON Schema（検証の正本） |
| `tools/resolve.py` | 検証 + 展開エンジン（resolver） |
| `control-node/` | 制御 VM の構築（自前ブートストラップ） |
| `ansible/` | 構築ロジック（roles / playbooks / 動的インベントリ） |
| `packer/` | golden VHDX イメージ生成 |
| `scripts/` | Hyper-V 冪等ヘルパー |
| `tests/` | resolver / スキーマのテスト |

## ステータス

- ✅ スキーマ確定（パターン C ハイブリッド）/ resolver / 検証 / DryRun プラン（pytest 10/10）
- ✅ L0→L1 冪等プロビジョニング（実機検証済：作成→再実行 no-change→nested/静的メモリ/MAC spoof）
- ✅ イメージ整備フロー（Windows=ISO配置→自動ビルド / Ubuntu=固定URL自動DL+変換）
- ✅ 制御ノード自動構築（Phase 1：実機で SSH 疎通 + 内蔵 Ansible ping=pong 実証）
- ✅ 本線疎通（Phase 2：制御 VM の Ansible → WinRM → ホスト Hyper-V を実機貫通。win_ping ok + Get-VMHost 取得）
- 🚧 L1 起動後の L1 内側 Ansible 実行（同経路で展開予定 / Windows golden ISO 待ち）
- 🚧 AD（Phase 4）/ クラスタ+S2D（Phase 3-4）/ Azure Local 隔離（Phase 5）/ GUI（Phase 7）

進捗の詳細は [`plan.md`](plan.md) §8 フェーズ計画を参照。
