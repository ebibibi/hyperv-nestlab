# 高度ワークロード: フェイルオーバークラスタ + S2D / Azure Local

コア (Windows / Linux / AD フォレストの L2) は実機検証済み。本書はその上に載る
2 つの高度ワークロードの設計と現状をまとめる。いずれも既存の宣言フロー
(resolve → L1 → L2 作成) の上に、L1 踏み台の PowerShell Direct でゲスト内構成を積む。

---

## 1. フェイルオーバークラスタ + Storage Spaces Direct (S2D)

### 宣言 (`l2/fileserver-s2d.yml` 既存)
```yaml
groups:
  - name: fileservers
    name_prefix: fs
    count: 2
    ip_from: 10.10.0.21
    data_disks: { count: 4, size_gb: 100 }   # S2D キャパシティ (l2_vm が差分OS + データ差分で作成)
    roles: [ File-Services, Failover-Clustering ]
    cluster:
      name: fscluster
      ip: 10.10.0.30
      s2d: true
      witness: { type: fileshare, host: dc01 }
      role: { type: file_server, volume_gb: 200 }
```
resolver はこれを vms (fs01, fs02 / 各 data_disks×4) + clusters (fscluster) に展開する。

### 構成手順 (L1踏み台 PowerShell Direct で各ノードへ)
1. 各ノードを AD 参加 (Initialize-AdForest と同じ要領)。
2. `Install-WindowsFeature Failover-Clustering, FS-FileServer -IncludeManagementTools`。
3. データディスク (l2_vm が `*-dataN.vhdx` で接続済み) をオンライン化。
4. `Test-Cluster` → `New-Cluster -Name fscluster -Node fs01,fs02 -StaticAddress 10.10.0.30 -NoStorage`。
5. `Enable-ClusterStorageSpacesDirect -Confirm:$false`。
6. `New-Volume -StoragePoolFriendlyName ... -FileSystem CSVFS_ReFS -Size 200GB`。
7. ファイル共有ウィットネス: `Set-ClusterQuorum -FileShareWitness \\dc01\witness`。
8. `Add-ClusterScaleOutFileServerRole`。

すべて冪等化 (Get → 無ければ作成) し、`scripts/Initialize-Cluster.ps1` (Initialize-AdForest と
同型の二段 PS Direct オーケストレータ) として実装予定。Ansible `cluster_s2d` ロールは
同ロジックの Ansible 版を担う。

### 現状
- ✅ resolver がクラスタ/データディスクを展開 (pytest)。
- ✅ `l2_vm` ロールがデータディスク (差分でなく動的 VHDX) を冪等接続。
- 🚧 クラスタ形成/S2D 有効化の二段 PS Direct オーケストレータは未実装 (足場のみ)。
- 注意: Nested + S2D は L1 のディスクスタックに負荷。検証用途 (本番ストレージではない)。

---

## 2. Azure Local (旧 Azure Stack HCI)

### 方針: 別管理 (隔離)
Azure Local は Arc/クラウド登録に依存し、原則② (決定性/オフライン) を素の Nested と
同じ土俵では満たせない。よって**別ライフサイクル・別ロール (`azure_local`)** に隔離し、
汎用ラボとは混ぜない (plan.md §6 の決定)。

### 実装: 既存 OSS をラップ
車輪の再発明をせず、実績ある OSS をラップする:
- **microsoft/AzStackHCISandbox** — 単一 Hyper-V ホスト上に Azure Local 検証環境を一括展開。
- **schmittnieto/AzSHCI** — Azure Local 2 ノード等の構築スクリプト群。

`azure_local` ロール (または `scripts/Initialize-AzureLocal.ps1`) は、L1 を「サンドボックス
ホスト」と見なして上記 OSS を取得・実行し、その内側に Azure Local ノードを立てる。
Azure 登録に必要なテナント/サブスクリプション等は専用の宣言ブロックで受け取る
(ラボの他要素とは独立)。

### 現状
- ✅ ロールを `azure_local` に隔離 (汚染防止)。
- 🚧 OSS ラッパは未実装 (足場 + 本書の方針のみ)。Azure Local 用 ISO/イメージは
  利用者が用意する必要があり、取得手順は OSS 側に準拠する。

---

## まとめ
| ワークロード | 宣言 | resolver | VM/ディスク作成 | ゲスト内構成 |
|---|---|---|---|---|
| Windows L2 | ✅ | ✅ | ✅ | ✅ (golden unattend) |
| Linux L2 | ✅ | ✅ | ✅ | ✅ (cloud-init) |
| AD フォレスト | ✅ | ✅ | ✅ | ✅ (PS Direct) |
| クラスタ+S2D | ✅ | ✅ | ✅ (データディスク) | 🚧 足場 |
| Azure Local | 方針確定 | — | — | 🚧 OSS ラップ予定 |
