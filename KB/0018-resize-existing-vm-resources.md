# 0018 — 展開済みVMの vCPU/メモリ変更（宣言値の再適用・VMオフ必須）

## 症状 / やりたいこと

一度 `bootstrap.ps1` で展開した L2（dc01 等）や L1 の **メモリ/CPU だけを後から増減**したい。

## 原因（旧挙動）

- **L2 ロール `ansible/roles/l2_vm/tasks/main.yml` は create-only だった**: `Set-VMProcessor`/`Set-VMMemory` が
  `if (-not (Get-VM ...))` の中だけにあり、**既存VMには再適用されない**。宣言ファイルの `cpu`/`memory_gb` を
  書き換えて再実行しても変わらなかった。
- L1 の `Ensure-LabVm`（`scripts/HyperVLab.psm1.ps1`）はドリフトを再適用する分岐があったが、**`Stop-VM` が無く
  起動中VMには適用できなかった**（静的メモリ・CPU数の変更は Hyper-V 仕様で VM オフ必須）。

## 対策（現在の挙動）

宣言ファイル（例 `l2/ad-forest.yml` の `memory_gb` / `cpu`、`l1/standard-host.yml` の `l1.memory_gb` / `l1.cpu`）を
書き換えて `bootstrap.ps1` を再実行すれば、**その値へ冪等に収束**する。

- `l2_vm` ロールに「L2 のリソースを宣言値へ調整」タスクを追加。ドリフトがある時だけ実施。
- `Ensure-LabVm` を「ドリフト時のみ停止→適用→（呼び出し側が起動）」に変更。
- **重要（Hyper-V 仕様）**: 静的メモリ・CPU数・`ExposeVirtualizationExtensions` の変更は **VM がオフでないと不可**。
  そのため**ドリフト検出時に該当VMを一旦 `Stop-VM -Force`（確認なしのゲストシャットダウン）して適用**し、後続の
  起動タスクで立ち上げ直す。= 対象VMに数十秒〜のダウンが発生する（ラボなので許容）。
- 動的メモリなら稼働中に Min/Max 内で変えられるが、**nested を有効にした L1 は動的メモリ不可（静的必須）**。

### 使い方

```powershell
# 例: dc01/mem01 を 4GB -> 8GB に。l2/ad-forest.yml の memory_gb を編集してから:
pwsh -NoProfile -File .\bootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\ad-forest.yml
# 既存VMはドリフト分（メモリ/CPU）だけ停止→適用→再起動され、他は no-change で収束。
```

## 教訓 / 汎用ノウハウ

- 「作成時だけ設定」パターンは典型的な冪等性の穴。**存在チェックの外に reconcile を置く**のが冪等の基本。
- Gen2＋静的メモリ＋nested はホットリサイズ不可。リソース変更＝停止を伴うと割り切って設計する。
- ドリフト検出（現在値≠宣言値）でゲートすれば、同一宣言の再実行では停止が起きず no-change を保てる。
