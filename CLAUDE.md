# CLAUDE.md — hyperv-nestlab 作業メモ (Claude 向け)

このリポジトリで作業する際の前提・約束ごと。

## 作業の進め方 (ユーザーの希望)
- **すべてフォアグラウンドで待つこと。** バックグラウンド実行＋完了通知は通知が届かない
  ことがあるため使わない。長時間タスクでも前面で同期的に待ち、結果をその場で確認・報告する。
  （PowerShell/Bash ツールの最大タイムアウトは 600000ms = 10 分。これを超えそうな処理は
  事前に見積もり、可能なら分割するか、それでも前面で待てる形にする。）
- Git は逐次コミットして、コード一発で再現できる状態を保つ。
- 大容量・機密物 (VHDX/ISO/鍵/data/build) は `.gitignore` 済み。コミットしない。

## リポジトリの場所 (重要)
- **正本は `D:\nestedhyper-v`**。GitHub: https://github.com/ebibibi/hyperv-nestlab (origin/master)。
- `C:\Users\Administrator\nestedhyper-v` は**古い**。触らない。
- C: は空き容量が少ない。VHDX 等の実体は必ず D: (data root) へ。

## 3 つの絶対基準 (設計の芯)
1. 前提条件は「Hyper-V サーバーがあること」だけ。他は自己ブートストラップ。
2. どの環境でも決定論的に同じ環境ができる (版固定・ベンダリング・宣言的設定)。
3. 誰もが使い回せる (単一エントリ bootstrap.ps1・ハードコードなし・ドキュメント同梱)。

## 構成の要点
- 3 層: L0 (物理 Hyper-V) / L1 (Nested ホスト VM) / L2 (L1 内の VM)。
- 構築ロジックは Ansible 一本化。制御 VM (Ubuntu, 10.20.0.10) 上で実行。
- L0 操作 (NAT/L1/制御VM/golden 配送/ラボストア) はホスト側 PowerShell + PowerShell Direct。
- L1 内部 (Hyper-V 役割/L2/AD/クラスタ) は Ansible (制御VM → WinRM → L1)。
- ネットワーク: L1 は CtrlNAT(10.20.0.0/24, L1=10.20.0.20)。L2 は LabNAT(10.10.0.0/24)。

## ハマりどころ (既知・解決済み)
- **win_powershell の引数は文字列で渡る。** `"4"*1GB` は文字列反復になり OutOfMemoryException。
  数値を使うパラメータは必ず `param([int]$MemGB)` 等で型を明示する。
- win_powershell は既定で非終端エラーを握りつぶす。`error_action: stop` +
  `$ErrorActionPreference='Stop'` を付けて失敗を必ず表面化させる。
- ホストは**日本語ロケール**。統合コンポーネント名等は英語名で引けない。ID で特定する
  (例: Guest Service Interface = 6C09BB55-...)。
- group_vars は**インベントリ隣接** (`ansible/inventory/group_vars/`) に置く。動的インベントリ
  スクリプト隣接でないと読まれない。
- scp 後の `ansible/` は world-writable になり ansible.cfg が無視される。`chmod -R go-w` する
  (Invoke-Ansible.ps1 で対応済み)。
- L1 の OS ディスクは golden 由来で 40GB と小さい。golden/L2 は L1 に増設する
  **ラボストア (L:, Add-L1LabStore.ps1)** に置く。L2 OS は **差分(ディファレンシング)ディスク**。
- L1 admin (golden 既定): `Administrator` / `P@ssw0rd-Lab-Change!`。

## 主要スクリプト
- `bootstrap.ps1` — 単一エントリ。
- `scripts/Copy-GoldenToL1.ps1` — golden を L1 (L:\images) へ Copy-VMFile 配送。
- `scripts/Add-L1LabStore.ps1` — L1 にラボストア (L:) を増設・初期化。
- `control-node/Invoke-Ansible.ps1` — 制御VMへ同期し ansible-playbook 実行。
- `tools/resolve.py` — L1+L2 宣言 → build/resolved.json に展開・検証。
