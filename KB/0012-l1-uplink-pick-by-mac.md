# 0012 — L1 の制御 IP が内部スイッチ側に載って「No route to host」

## 症状

2 回目以降の bootstrap (別 L2 構成への切替や冪等再実行) で `setup_l1.yml` の最初の `win_ping`
が L1 に届かず失敗する。直前の `Initialize-L1Network` は成功扱いなのに、である:

```
==> L1 を CtrlNAT に接続し 静的IP/WinRM を構成 (PowerShell Direct)
  [l1net] L1 の NIC は既に CtrlNAT に接続済み
  [l1net] IP 10.20.0.20 は設定済み
  [l1net] IP 確認: 10.20.0.20
  ...
==> L1 内に Hyper-V 役割 + LabNAT を構成 (Ansible: setup_l1.yml)
TASK [win_ping] ****
fatal: [nested-lab-01]: UNREACHABLE! => {"msg": "ntlm: HTTPConnectionPool(host='10.20.0.20',
  port=5985): Max retries exceeded ... [Errno 113] No route to host"}
```

L1 の中を見ると、制御プレーン IP `10.20.0.20` が**本来の CtrlNAT アップリンクではなく
内部スイッチの host vNIC `vEthernet (LabNAT)` に載っていた**。CtrlNAT 接続側の NIC
(`イーサネット 2`) は `Up` だが IPv4 が空。LabNAT のゲートウェイ `10.10.0.1` も消えていた:

```
vEthernet (LabNAT)  10.20.0.20/24   ← 誤: 本来は 10.10.0.1
イーサネット 2       (IPv4 なし)      ← 本来ここに 10.20.0.20
```

制御 VM は CtrlNAT セグメント上で `10.20.0.20` を ARP するが、その IP を持つのは別セグメント
(内部 LabNAT) のアダプタなので誰も応答せず「No route to host」になる。

## 原因

`Initialize-L1Network.ps1` が L1 内のアップリンクを **「最初の Up な NIC」** で選んでいた:

```powershell
$a = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
```

- **クリーン構築では問題ない。** その時点で Up な NIC は CtrlNAT アップリンク 1 枚だけ。
- しかし `setup_l1.yml` が内部スイッチ `LabNAT` を作ると、L1 には Up な NIC が
  **2 枚** (`イーサネット 2` と `vEthernet (LabNAT)`) になる。`Select-Object -First 1` の
  順序は保証されず、再実行で `vEthernet (LabNAT)` を掴むことがある。
- 掴むと、その「冪等化」処理が当該アダプタの既存 IP (`10.10.0.1`) を掃除して `10.20.0.20` を
  載せ替える。結果、制御 IP が内部側に移り、CtrlNAT 側は無 IP、LabNAT GW も消える。
- 冪等チェックが `Get-NetIPAddress … -eq 10.20.0.20`「存在するか」だけを見ていたため、
  **誤ったアダプタに載っていても「設定済み」と誤認**して壊れた状態を温存した。

典型的な「クリーンでは通る・再実行で初めて壊れる」パターン (cf. [[0011-control-vm-memory-ssh-hang]])。

## 対策

アップリンクを **MAC で一意特定**する。L0 側で L1 仮想 NIC (CtrlNAT 接続) の MAC を確定し、
スクリプトブロックへ渡して L1 内では**その MAC に一致するアダプタだけ**を対象にする
(`scripts\Initialize-L1Network.ps1`):

```powershell
# L0 側
$mac = (Get-VMNetworkAdapter -VMName $VMName |
        Where-Object { $_.SwitchName -eq $Switch } | Select-Object -First 1).MacAddress
# L1 内
$want = ($Mac -replace '[-:]','').ToUpper()
$a = Get-NetAdapter | Where-Object {
        ($_.MacAddress -replace '[-:]','').ToUpper() -eq $want -and $_.Status -eq 'Up' } |
     Select-Object -First 1
```

あわせて、**正しいアダプタ以外に紛れ込んだ制御 IP を剥がす**処理を追加 (過去の誤選択で
壊れた状態からの自己修復):

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -eq $Ip -and $_.InterfaceIndex -ne $idx } |
    Remove-NetIPAddress -Confirm:$false
```

## 教訓 / 汎用ノウハウ

- **「最初の○○」で対象を選ぶな。** `Select-Object -First 1` / `... | head -1` は、対象が 1 個の
  間は動くが、構成が育って候補が増えた瞬間に非決定的になる。NIC・ディスク・VM など
  「あとから増える」リソースは **MAC / シリアル / 名前など不変キーで一意特定**する。
- **冪等チェックは「存在するか」でなく「正しい場所にあるか」を見る。** 望む値がどこかに
  あるだけで「設定済み」と判断すると、誤配置を温存して別の場所で失敗する。
- **自己修復を入れる。** 過去の不具合で壊れた状態に出くわしても、正しいアダプタ以外から
  剥がす等で収束できるようにしておくと、手動掃除なしで再実行が通る。
- ネスト環境の `No route to host` (Errno 113) は **同一サブネット内の ARP 不一致**を疑う。
  ルーティングでなく「その IP を名乗るべきインターフェイスが正しいか」を最初に見る。
