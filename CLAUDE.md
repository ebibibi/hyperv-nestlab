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
- **開発用(正本)は `D:\hyperv-nestlab-dev`**。GitHub: https://github.com/ebibibi/hyperv-nestlab (origin/master)。
  - 旧名 `D:\nestedhyper-v` から改名済み (ユーザーのテスト用 clone と区別するため)。
- `D:\nestlab-test` 等はユーザーが GitHub から clone した**テスト用**。開発側からは触らない。
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
- **Windows で clone すると git autocrlf でテキストが CRLF になる。** Linux 側で実行/解釈する
  ファイル (inventory の `.py` shebang、bash に渡す here-string 等) が CRLF だと壊れる
  (`set: -<CR>`, `python3\r: No such file`)。対策: `.gitattributes` で Linux 物は LF 固定 +
  Invoke-Ansible.ps1 が同期後に CR 除去 + here-string を LF 正規化 (両方済み)。
- **制御 VM は cloud-init で ansible-core しか入らない。** `win_ping` 等 (ansible.windows) と
  WinRM 接続の `pywinrm` は別途必要。Invoke-Ansible.ps1 が requirements.yml の collection +
  pywinrm==0.4.3 を版固定で導入 (マーカー `~/.nestedlab-deps-ok`)。NTLM なので pywinrm が
  requests_ntlm を連れてくる。galaxy/pypi 到達 (CtrlNAT NAT) が前提。
- **L1 内 Hyper-V は labstore/L2 より先に入れる。** `Set-VMHost`/`New-VM` は L1 内 Hyper-V 必須。
  bootstrap は setup_l1 (Hyper-V 導入, 再起動あり) → labstore → golden 配送 → L2 の順。
- **golden 由来の L1 は素のままでは制御 VM から到達不能** (CtrlNAT 未接続/静的IP無し/WinRM未構成)。
  `scripts/Initialize-L1Network.ps1` が PowerShell Direct で L1 を CtrlNAT 接続 + 10.20.0.20 静的IP +
  WinRM 有効化 + FW 5985 + LocalAccountTokenFilterPolicy=1。setup_l1 の前に実行。
- **L2 を Ansible 制御するための到達性 = ルータ化 + 最小 PS Direct。** L1 を IP forwarding で
  ルータにし (setup_l1)、制御 VM に静的ルート 10.10.0.0/24→10.20.0.20 (cloud-init)。**LabNAT は
  NAT を張らない (ルーテッド)** — NetNat があると戻りを SNAT してルーティングを壊す。Windows L2 の
  初期IP/改名/WinRM/CredSSP は `Initialize-L2Access.ps1` (PS Direct) で焼き、以降は Ansible。
- **S2D は golden が Datacenter エディションでないと不可** (Standard だと Enable-ClusterS2D が
  0x80070032 "S2D not supported")。Build-WindowsGoldenDism は Datacenter Eval を選ぶ (上位互換)。
- **クラスタ/S2D の AD オブジェクト作成 (CNO/VCO) は二段ホップ** → `create_cluster.yml` は
  ドメイン管理者 + **CredSSP** transport で実行 (ノードに Enable-WSManCredSSP -Role Server)。
  クラスタ cmdlet は `-Name`/`-Cluster <名>` を使わない (DNS 解決で失敗) — メンバ上でローカル実行。
- **AD: ADWS が自動起動しきれず Get-ADDomain が偽になる / dcpromo が DNS ゾーンを作り切らない**
  ことが入れ子であり、Initialize-AdForest が「ADWS 明示起動」「forward zone + SRV の健全化」を行う。
- **制御 VM の rootfs は cloud イメージ既定で ~3.5GB と小さい。** Ensure-ControlNode が OS ディスクを
  32GB に拡張 (cloud-init growpart) してから起動 (pip/collection で枯渇するため)。

## 主要スクリプト
- `bootstrap.ps1` — 単一エントリ (解決→images(Datacenter golden)→L1→制御VM→L1到達→setup_l1→
  labstore→golden配送→create_l2→Initialize-L2Access→AD→cluster の順)。
- `scripts/Initialize-L1Network.ps1` — L1 を CtrlNAT 接続 + 静的IP/WinRM (PS Direct, setup_l1 前)。
- `scripts/Initialize-L2Access.ps1` — Windows L2 の 静的IP/改名/WinRM/CredSSP 最小ブート (PS Direct)。
- `scripts/Initialize-AdForest.ps1` — DC 昇格 + メンバ参加 + DNS 健全化 (二段 PS Direct)。
- `ansible/playbooks/create_cluster.yml` — Failover Cluster + S2D + SOFS (Ansible/CredSSP)。
- `scripts/Copy-GoldenToL1.ps1` — golden を L1 (L:\images) へ Copy-VMFile 配送。
- `scripts/Add-L1LabStore.ps1` — L1 にラボストア (L:) を増設・初期化。
- `control-node/Invoke-Ansible.ps1` — 制御VMへ同期し collection/pywinrm[credssp] 導入 + playbook 実行。
- `tools/resolve.py` — L1+L2 宣言 → build/resolved.json に展開・検証。
