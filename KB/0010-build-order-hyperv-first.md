# 0010 — L1 内 Hyper-V は labstore/L2 より先に入れる

## 症状

bootstrap の途中、ラボストア増設や L2 作成の段で:

```
Set-VMHost : 用語 'Set-VMHost' は、コマンドレット ... として認識されません。
New-VM : ... 認識されません。
```

## 原因

これらの cmdlet は **L1 の中に Hyper-V 役割が入っていて初めて使える**。bootstrap の順序が悪く、
L1 に Hyper-V を入れる前にラボストア (`Add-L1LabStore`) や L2 作成 (`create_l2`) を走らせていた。

## 対策

bootstrap の順序を「**L1 内 Hyper-V 導入 → ラボストア → golden 配送 → L2 作成**」に修正
(commit 57577a2)。具体的には `setup_l1.yml` (Hyper-V 役割導入 + 再起動あり + LabNAT + ルータ化) を
labstore より**前**に持ってくる。現在の bootstrap 順:

```
解決 → images → L1作成 → hostWinRM → 制御VM(CtrlNAT) → Initialize-L1Network → ping_l0
→ setup_l1 (Hyper-V/LabNAT/router) → Add-L1LabStore → golden配送 → (seed) → create_l2
→ Initialize-L2Access → AD → cluster
```

## 教訓 / 汎用ノウハウ

- **役割/機能のインストールは、その役割の cmdlet を使う全ステップより前に置く。** 当たり前に見えて、
  入れ子 (L0 の Hyper-V で L1 を作り、L1 の中でまた Hyper-V を使う) だと「どの層にまだ Hyper-V が
  無いか」を取り違えやすい。
- Hyper-V 役割導入は**再起動を伴う**。bootstrap のその段で確実に再起動を挟み、後続が新しい
  cmdlet を前提にできる状態にしてから進む。
- 「`xxx は認識されません`」は、依存役割/モジュールの**導入順**か**実行する層**の取り違えを疑う。
