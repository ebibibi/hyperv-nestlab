# CLAUDE.md — hyperv-nestlab 作業メモ (Claude 向け)

このリポジトリで作業する際の前提・約束ごと。

## 作業の進め方 (ユーザーの希望)
- **すべてフォアグラウンドで待つこと。** バックグラウンド実行＋完了通知は通知が届かない
  ことがあるため使わない。長時間タスクでも前面で同期的に待ち、結果をその場で確認・報告する。
  （PowerShell/Bash ツールの最大タイムアウトは 600000ms = 10 分。これを超えそうな処理は
  事前に見積もり、可能なら分割するか、それでも前面で待てる形にする。）
- Git は逐次コミットして、コード一発で再現できる状態を保つ。
- 大容量・機密物 (VHDX/ISO/鍵/data/build) は `.gitignore` 済み。コミットしない。
- **ハマりどころは Claude のメモリに書かない。リポジトリ内の `KB/` に記事として書き溜める。**
  この OSS を作る中で踏んだ罠は `KB/NNNN-*.md` に追記し (`KB/README.md` が索引と書き方ルール)、
  「同じ罠に二度はまらない」記録 兼 汎用ノウハウにする。メモリ (`.claude/.../memory`) は
  プロジェクトの状態・ゴール・約束ごと専用で、技術的ハマりは置かない。

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
- **構築は PowerShell / PowerShell Direct と Ansible のハイブリッド**（「Ansible 一本」ではない）。
  分担の境界は **「IP + WinRM がもう在るか」**: 整った後の“内側の定常構成”だけ Ansible、それ以前と
  L0 操作は PowerShell。制御 VM (Ubuntu, 10.20.0.10) が Ansible の実行主体。
  - **L0 操作** (NAT / L1作成 / 制御VM / golden配送 / ラボストア) … ホスト **PowerShell** (Hyper-V cmdlet)。
  - **“ネットワーク前”のブートストラップ** (L1/L2 の 静的IP・WinRM有効化・改名・日本語キーボード・RDP、
    および AD 昇格/参加) … **PowerShell Direct** (VMBus。IP も WinRM も無い段でも届く。AD は二段ホップ)。
  - **IP+WinRM が整った後の L1/L2 内部** … **Ansible** (制御VM→WinRM)。`setup_l1` (Hyper-V役割+LabNAT) /
    `create_l2` (L2作成) / `create_cluster` (Failover Cluster+S2D, CredSSP)。
- ネットワーク: L1 は CtrlNAT(10.20.0.0/24, L1=10.20.0.20)。L2 は LabNAT(10.10.0.0/24)。

## ハマりどころ → `KB/` を見ること

既知のハマりどころと解決法は**すべて `KB/` に記事化**している (`KB/README.md` が索引)。
新たに踏んだら**メモリではなく KB に追記**する (上の「作業の進め方」のルール参照)。主な記事:

- `KB/0001` Windows clone の CRLF が Linux 側を壊す (`.gitattributes` で LF 固定)
- `KB/0002` 制御VMには ansible-core しか無い (collection / pywinrm[credssp] を版固定導入)
- `KB/0003` 制御VM→L2 到達性 = L1 ルータ化 + ルーテッド LabNAT (NetNat 撤去) + 最小 PS Direct
- `KB/0004` DISM で golden を焼く / **S2D には Datacenter エディション必須** (Standard 不可)
- `KB/0005` 言語別 ISO の冪等性 (冪等キーはファイル名単位 / 検証失敗でも消さない)
- `KB/0006` 入れ子クラスタ + S2D (CredSSP 二段ホップ / cluster cmdlet は `-Name` 不可 / CacheState Disabled)
- `KB/0007` 入れ子 dcpromo は ADWS と DNS ゾーンを作り切らない (昇格後の健全化)
- `KB/0008` win_powershell の罠 (引数は文字列 / 既定でエラー握りつぶし / 日本語ロケール)
- `KB/0009` cloud イメージの rootfs (~3.5GB) は起動前に VHD 拡張する
- `KB/0010` L1 内 Hyper-V は labstore/L2 より先に入れる (`Set-VMHost`/`New-VM` の前提)

補足 (KB 化するほどでもない定常事実):
- L1/L2 admin (golden 既定): `Administrator` / `P@ssw0rd-Lab-Change!`。
- L1 の OS ディスクは golden 由来で 40GB と小さい。golden/L2 は **ラボストア (L:, Add-L1LabStore.ps1)**
  に置き、L2 OS は **差分(ディファレンシング)ディスク**。

## 主要スクリプト
- `bootstrap.ps1` — 単一エントリ (解決→images(Datacenter golden)→L1→制御VM→L1到達→setup_l1→
  labstore→golden配送→create_l2→Initialize-L2Access→AD→cluster の順)。完了時にフェーズ別構築時間を表示。
- `teardown.ps1` — bootstrap の対。L1(+中の L2 をディスクごと)+制御VM を削除。既定でスイッチ/build は残す
  (`-IncludeSwitch`/`-IncludeBuild`/`-Force`/`-KeepControlNode`)。
- `scripts/Initialize-L1Network.ps1` — L1 を CtrlNAT 接続 + 静的IP/WinRM (PS Direct, setup_l1 前)。
- `scripts/Initialize-L2Access.ps1` — Windows L2 の 静的IP/改名/WinRM/CredSSP 最小ブート (PS Direct)。
- `scripts/Initialize-AdForest.ps1` — DC 昇格 + メンバ参加 + DNS 健全化 (二段 PS Direct)。
- `ansible/playbooks/create_cluster.yml` — Failover Cluster + S2D + SOFS (Ansible/CredSSP)。
- `scripts/Copy-GoldenToL1.ps1` — golden を L1 (L:\images) へ Copy-VMFile 配送。
- `scripts/Add-L1LabStore.ps1` — L1 にラボストア (L:) を増設・初期化。
- `control-node/Invoke-Ansible.ps1` — 制御VMへ同期し collection/pywinrm[credssp] 導入 + playbook 実行。
- `tools/resolve.py` — L1+L2 宣言 → build/resolved.json に展開・検証。
