# Nested Hyper-V IaC 基盤 — 計画書 (plan.md)

> 既存の Hyper-V サーバー上に Nested Hyper-V 環境を「コードで定義し、冪等・決定的に」構築するための基盤。
> 本書は設計の最上位ドキュメント。詳細な YAML スキーマ定義は別途 `schema.md`（次フェーズで策定）に記載する。

---

## 1. 目的とスコープ

既存の Hyper-V サーバーの中に、Nested Hyper-V のホスト VM を建て、その中で仮想スイッチ・ネットワーク・仮想マシン群を構築する。これを Infrastructure as Code として宣言的に定義し、何度実行しても同じ結果へ収束させる。

対象とする構築物（層モデル）:

| 層 | 内容 | 役割 |
|---|---|---|
| **L0** | 物理 Hyper-V サーバー（既存・唯一の前提） | この上に L1 を建てる |
| **L1** | Nested Hyper-V ホスト VM（中で Hyper-V が動く） | Hyper-V 役割有効化・仮想スイッチ・ネットワーク |
| **L2** | L1 の中で動く VM 群（Windows / Linux / AD など） | 実際のワークロード／検証環境 |

---

## 2. 譲れない 3 原則（最上位の判断基準）

| # | 原則 | 設計ルールへの翻訳 |
|---|---|---|
| ① | 前提条件は **Hyper-V サーバーがあること、ただそれだけ** | 実行に必要な制御環境・ランタイム・ツール類はすべて **自前でブートストラップ** する。利用者に手作業の事前準備をさせない |
| ② | どの環境でも、実行すれば **安定的・一義的に同じ環境** が出来上がる | **バージョン固定 + 成果物のベンダリング（同梱）+ オフライン耐性**。ネット依存＝非決定性の元として極小化。設定は単一の宣言ファイルに集約 |
| ③ | **誰もが使い回せる** | **エントリポイントは 1 つ**（スクリプト 1 本の実行で完結）。パス・名前のハードコード禁止、すべて変数化。ドキュメント同梱 |

これら 3 原則は、以降のあらゆる技術判断より優先される。判断に迷ったら原則に立ち返る。

---

## 3. アーキテクチャ：self-bootstrapping 型

利用者の操作は **「Hyper-V サーバー上で `bootstrap.ps1` を 1 回実行する」だけ**。

```
利用者がやること: bootstrap.ps1 を Hyper-V サーバー上で実行
        │
        ▼
[bootstrap.ps1]  (Hyper-V 上の PowerShell — Windows に必ず存在)
  1. ホストの PSRemoting / WinRM を冪等に有効化
  2. 同梱の固定 Linux イメージから「制御 VM (ctrl-node)」を構築
        └ Ansible / Python をバージョン固定で内蔵
  3. 制御 VM へ inventory と宣言設定を流し込み、以降をハンドオフ
        │
        ▼
[制御 VM: Ansible]  ※当初構想。実装では下記「レイヤ分担の確定」のハイブリッドに収束した
  ├─ L0→L1 : Nested ホスト作成 + ExposeVirtualizationExtensions 等の Nested 必須設定
  ├─ L1 内部: Internal スイッチ + New-NetNat（NAT 自己完結ネットワーク）
  ├─ L2     : Windows / Linux VM 群（Autounattend / cloud-init で初期化）
  ├─ AD     : 既存 create_ad.yml を role 化して移植
  └─ azure_local: 別 OSS をラップ（隔離・別ライフサイクル）
```

> 注: この「すべて Ansible に一本化」は初期構想。実装では、IP+WinRM が無い段の
> ブートストラップ (L1/L2 の 静的IP/WinRM/改名/RDP) と AD 昇格は **PowerShell Direct** に
> 落ち着いた (下記「レイヤ分担の確定」)。最新の正確な対応は README「役割分担」/ CLAUDE.md を参照。

### なぜ「制御 VM 方式」なのか（原則①の遵守）

Ansible の制御ノードは Windows 上でネイティブに動作しない（Python + Linux 環境が必要）。これをそのまま要求すると「Hyper-V サーバー以外の前提」が増え、原則①に反する。

→ **私たちは Hyper-V を使えるのだから、制御ノード自体を Hyper-V 上の小さな VM として自動構築する。** これにより「利用者が用意するのは Hyper-V サーバーだけ」を守ったまま、Ansible の資産と宣言的な構築ロジックを活かせる。制御 VM は版固定イメージなので、どの環境でも同一の Ansible 実行環境が再現される（原則②）。

### レイヤ分担の確定（実装で確定した refinement）

実装を進める中で、責務を次のように明確化した：

- **L0 レベルの Hyper-V 操作（L0 用スイッチ / L1 ホスト VM / 制御 VM）は、ホスト上の PowerShell（`scripts\HyperVLab.psm1.ps1` + `bootstrap.ps1`）が担当。** ホスト上で直接 cmdlet を叩くのが最も素直で、WinRM 二重化も不要。
- **“ネットワーク前”のブートストラップ（L1/L2 の 静的IP・WinRM有効化・改名・RDP・日本語キーボード、および AD 昇格・参加）は、ホスト上の PowerShell Direct（VMBus）が担当。** IP も WinRM も無い段でも届くため。AD は DC への二段ホップを伴うのでなおさら。
- **IP+WinRM が整った後の L1 内側（Hyper-V 役割 / `LabNAT` / L2 作成 / クラスタ+S2D）は Ansible が担当**（`setup_l1` / `create_l2` / `create_cluster`）。

これは「構築ロジックの“定常構成”部分を Ansible に集約」しつつ、Ansible が前提とする IP+WinRM が無い段（と L0 操作）を PowerShell / PowerShell Direct に任せる現実的な切り分け。`scripts\HyperVLab.psm1.ps1` の冪等関数は実機 Hyper-V で **作成 → 再実行 no-change（冪等）→ nested/静的メモリ/MAC spoof 収束** を検証済み（`tests\Smoke-HostProvision.ps1`）。

---

## 4. ネットワーク方針：L1 内 NAT で自己完結

L2 の外部接続は、L1 の中に `Internal` 仮想スイッチ + `New-NetNat` を構成して閉じる。L0 の物理ネットワーク構成に依存しないため、環境差に強く、再現性・移植性が高い（原則②③）。

---

## 5. 決定性・冪等性の担保メカニズム（原則②の心臓部）

- **バージョン固定**: 制御 VM イメージ、Ansible コレクション、Packer プラグイン、PowerShell モジュールをすべてピン留めする。
- **ベンダリング**: ベース OS イメージ・cloud image を同梱、または取得時にチェックサム検証する。オフラインでも一義的に再現できることを目標とする。
- **収束型タスク**: すべての Hyper-V 操作を「Get → 無ければ作成／期待状態でなければ収束」で実装する（New-VM, Set-VMProcessor, New-VMSwitch, New-NetNat など）。
- **状態はコードで宣言**: 宣言設定ファイルが唯一の真実（single source of truth）。実行のたびに同じ結果へ収束し、ドリフトを是正する。
- **2 回実行で no-change**: 冪等性の受け入れ条件として、連続実行で変更ゼロになることを自動テストで担保する。

---

## 6. Azure Local の隔離方針

Azure Local（旧 Azure Stack HCI）は素の Nested VM とは難易度が桁違い（多段ネスト、S2D 用複数ディスク、大容量リソース、そして **Azure Local 23H2 以降は Arc 経由のクラウドデプロイが標準**でインターネット / Azure 登録が前提）。これは原則②（決定性・オフライン耐性）と本質的に相いれない。

→ Azure Local 系は専用 role `azure_local` に **隔離** し、内部実装は既存 OSS をラップする。汎用ラボ（Win/Linux/AD）のライフサイクルとは完全に分離し、汎用側の決定性を汚さない。

参考 OSS:
- [microsoft/AzStackHCISandbox](https://github.com/microsoft/AzStackHCISandbox) — 単一 Hyper-V ホスト上に nested HCI 一式を構築
- [schmittnieto/AzSHCI](https://github.com/schmittnieto/AzSHCI) — PowerShell による Azure Local ラボの構築・運用

---

## 7. リポジトリ構成

```
nestedhyper-v/
├─ bootstrap.ps1              # ★唯一のエントリポイント（Hyper-V ホスト上で実行）
├─ env.example.yml           # 利用者が編集する唯一の宣言ファイル（スキーマは schema.md で定義）
├─ assets/                   # 同梱イメージ / チェックサム（ベンダリング）
├─ control-node/             # 制御 VM の定義（イメージ構築・版固定）
├─ ansible/
│  ├─ inventory/             # 動的インベントリ
│  ├─ playbooks/             # 01_l1 / 02_l1net / 03_l2 / ad / azure_local
│  ├─ roles/                 # nested_host / l1_network / l2_vm / ad / azure_local
│  └─ requirements.yml       # コレクション版固定
├─ packer/                   # golden VHDX（windows-server / linux）
├─ gui/                      # 将来フェーズ：薄い前面 GUI
├─ docs/                     # 利用手順・トラブルシュート
├─ tests/                    # 冪等性検証（2 回実行で no-change 等）
├─ plan.md                   # 本書
└─ schema.md                 # 宣言設定の YAML スキーマ定義（次フェーズで策定）
```

---

## 8. フェーズ計画

| Phase | 内容 | 完了の目安 |
|---|---|---|
| **0** | ✅ 土台：リポジトリ雛形、`bootstrap.ps1`、スキーマ/resolver、DryRun、pytest | 完了（10/10 test pass・DryRun 実機完走） |
| **1** | ✅ 制御ノード自動構築：固定 Linux イメージから制御 VM を建て Ansible を内蔵 | **実機 end-to-end 実証済**：cloud-init シード(CIDATA)投入→Gen2 VM 作成→SSH 疎通→制御 VM 内 `ansible -m ping`=pong（core 2.17.5）。再実行 no-change も確認 |
| **2** | 🟡 最小 PoC：L0→L1（**冪等エンジン実機検証済**）→ L1 内 NAT → Linux VM 1 台 | L0→L1 冪等検証済。**本線(制御 VM→WinRM→ホスト Hyper-V)実機貫通済**：`ansible.windows.win_ping`=ok + `Get-VMHost` 取得成功。L1 起動後に同経路で L1 内側へ展開（Windows golden ISO 待ち） |
| **2-net** | ✅ 本線配管：制御 VM の Ansible → WinRM → ホスト Hyper-V | 実機実証済。ホスト WinRM 冪等収束(`Ensure-HostWinRM`)、専用サービスユーザー(`Ensure-LabServiceUser`)、scp+ssh 配管(`Run-OnControl`/`Invoke-Ansible`)、`ping_l0.yml` で PLAY RECAP ok=3 failed=0 |
| **img** | ✅ golden イメージ整備：Windows=ISO配置→**DISM 自動ビルド** / Ubuntu=固定URL自動DL+変換 | 両 OS とも実機実証済。Windows は DISM 標準ツールのみで golden VHDX 生成 (14.25GB)・oscdimg/ADK 不要。**L1 を golden から実起動 (Running/nested=True) 確認** |
| **store** | ✅ 自己完結ストレージ構造：大容量データはリポジトリ配下 `data/` に集約 | C: 逼迫→D: 全面移行。VM ディスクは `data/vms/<name>/`、env `NESTEDLAB_DATA_ROOT` で上書き可。`Get-LabDataRoot` で一元解決 |
| **3** | L2 拡充：Windows Server（Autounattend / Packer）、複数 VM、台数・スペックを宣言で制御 | 宣言ファイルで Win/Linux 複数台を再現 |
| **4** | AD：既存 `create_ad.yml` を role 化して移植 | 宣言で AD/ドメイン環境を構築 |
| **5** | Azure Local（隔離）：`azure_local` role で既存 OSS をラップ | 隔離 role 経由で nested HCI ラボが立つ |
| **6** | オフライン / 決定性強化：ベンダリング完備、チェックサム検証、エアギャップ実行テスト | ネット遮断環境でも一義的に再現 |
| **7（後回し）** | GUI：宣言ファイルを編集し `bootstrap.ps1` を起動する薄い GUI（ローカル Web UI もしくは PowerShell 製ウィンドウ） | ボタン操作で「作成 / 削除 / 状態確認」 |

GUI はあくまで宣言ファイルを編集して同じエントリポイントを呼ぶ「薄い前面」とし、構築ロジックを二重化しない。

---

## 9. Nested Hyper-V 特有の必須設定（実装時のチェックリスト）

道具に関係なく、L1 作成時に以下が欠けると「中で VM が起動しない / 通信できない」状態になる。冪等タスクとして必ず織り込む。

- `Set-VMProcessor -ExposeVirtualizationExtensions $true`（仮想化拡張の公開）
- L1 は **動的メモリ OFF**（Nested ホストは固定メモリ必須）
- L2 を外部に出す場合の **MAC アドレススプーフィング**（本基盤の既定は NAT 自己完結のため依存は最小）
- L1 / L2 に十分な vCPU・RAM・ディスク

---

## 10. 主なリスクと対処

| リスク | 対処 |
|---|---|
| 制御 VM 方式で層が 1 つ増える | 原則①を守る代償として妥当と判断。Phase 1 で確実に自動化 |
| Server Core / 旧 Windows での挙動差 | Phase 1 で吸収・検証 |
| Azure Local のネット必須が原則②と衝突 | `azure_local` role に隔離して対処済み |

---

## 11. 次のアクション

1. **YAML スキーマの策定**（最重要・進行中の相談テーマ）。宣言設定ファイルが本基盤の利用者体験と再現性を決定づける中核。コードの書き方・スキーマ設計をしっかり詰めてから `schema.md` に確定する。
   - **L1 / L2 はファイル分離**。L1（Nested ホスト）は使い回す土台として共通化し、L2（中の VM 群）だけ差し替える。展開時に両ファイルを指定する：`bootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\<env>.yml`
   - **L2 スキーマの方向性は「パターン C：ハイブリッド」に決定**。既定値（`defaults`）＋まとめ書き（`count` / `ip_from` / `data_disks`）で短く書け、必要な箇所だけ `overrides` で低レベルのフル明示形に降りられる（エスケープハッチ）。「普段は短く、いざとなれば何でも制御」を両立する。
2. スキーマ確定後、Phase 0（リポジトリ雛形）へ着手。
