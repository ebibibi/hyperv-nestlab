# 0003 — 制御VMから L2 へ届かない (ルータ化 + ルーテッド LabNAT)

入れ子ラボで一番厄介だったネットワークの話。2 段階のハマりがある。

## ハマり A: golden 由来の L1 がそもそも制御VMから届かない

### 症状
制御 VM から L1 へ Ansible (WinRM) しようとすると `No route to host` (10.20.0.20)。

### 原因
golden から起こした L1 は **Default Switch に繋がっただけの素の状態**。CtrlNAT スイッチに
未接続、静的 IP 無し、WinRM 未構成。旧セッションでは手で構成していて**コード化されていなかった
「欠落ピース」**だった。

### 対策
`scripts/Initialize-L1Network.ps1` を新設し、**PowerShell Direct** (ネットワーク不要) で L1 を冪等構成:
CtrlNAT へ接続 + MAC spoof + `10.20.0.20/24` 静的 IP + DNS + プロファイル Private +
`Enable-PSRemoting` + FW 5985 + `LocalAccountTokenFilterPolicy=1`。**setup_l1 の前**に実行する。

## ハマり B: L1 は届くが、その先の L2 へ制御VMから届かない

### 症状
ルートを足しても制御 VM → L2 (10.10.0.x) が타임아웃。L1 上からは L2 に届く。

### 原因
当初 LabNAT に **NetNat (NAT)** を張っていた。NAT は L2 からの戻りパケットを **SNAT** して
送信元を書き換えるため、「制御VM→(L1ルーティング)→L2」の**ルーテッドな戻り経路が壊れる**。
NAT とルーティングを同じサブネットで混在させたのが敗因。

### 対策 (アーキ方針: ルータ化 + 最小 PS Direct)
- **LabNAT から NetNat を撤去し、純粋なルーティングにする** (`ansible/playbooks/setup_l1.yml` が
  既存の `<switch>-NAT` を削除)。
- **L1 をルータ化**: CtrlNAT 側 (10.20.0.20) と LabNAT 側 (10.10.0.1) の両インターフェースで
  `Set-NetIPInterface -Forwarding Enabled`。
- 制御 VM に**静的ルート** `10.10.0.0/24 → 10.20.0.20` を cloud-init で追加
  (`New-CloudInitSeed.ps1` の `-ExtraRoutes` / netplan)。
- L2 には DHCP が無いので、Windows L2 の**初期 IP / 改名 / WinRM / CredSSP だけ最小 PS Direct**
  (`scripts/Initialize-L2Access.ps1`) で焼く。Linux L2 は cloud-init。以降は全部 Ansible で制御。

これで「制御VM が Ansible で L2 を直接たたく」構成 (ユーザー要望) が成立。

## 教訓 / 汎用ノウハウ

- **同一サブネットで NAT とルーティングを混ぜない。** L2 をオーケストレータから直接触りたいなら、
  そのセグメントは**ルーテッド**にする (NAT は送信元を書き換えて戻りを壊す)。L2 のインターネット
  アクセスが要るなら、NAT は**別のアップストリーム境界**で 1 回だけ張る。
- **PowerShell Direct はネットワーク未構成のブートストラップに最適。** 「ネットワークを構成するため
  にネットワークが要る」鶏卵問題は、VMBus 経由の PS Direct で初期 IP/WinRM だけ焼いて断ち切る。
  以降は通常の WinRM/SSH に移行する (最小限に留めるのがコツ — 全部 PS Direct でやると二段ホップ地獄)。
- **「手で直したものは必ずコード化する」**。動いている環境は、たいてい誰かが手で埋めた欠落ピースを
  含んでいる。それを掘り起こしてスクリプト化するまで「冪等」とは言えない (ハマり A の教訓)。
