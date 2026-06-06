# 0011 — 制御VMのメモリ枯渇で scp/ansible が無限ハングする

## 症状

2 回目以降の bootstrap (冪等再実行) が、`create_l2.yml` 直前の「ansible/ と確定モデルを制御 VM へ
同期」の所で**無限に固まる**。ログは次の行で止まったまま進まない:

```
==> L1 -> L2  仮想マシン群の作成 (Ansible: create_l2.yml)
  [ansible] ansible/ と確定モデルを制御 VM へ同期
Warning: Permanently added '10.20.0.10' (ED25519) to the list of known hosts.
   ← ここから先に進まない (15分以上)
```

調べると:
- ホスト側に **scp/ssh プロセスが 1 つ残ったまま** (CPU ほぼ 0 = 転送が固まっている)。
- 制御 VM 側には **対応する転送プロセスが無く load average 0.00** (＝ハーフオープンで宙吊り)。
- 制御 VM の **総メモリが 540MB** しかない (`free -m` の total)。`Get-VMMemory` を見ると
  動的メモリの **Minimum が 512MB**、Maximum が 1TB (既定) のまま。

## 原因 (2 つが重なる)

1. **制御 VM の動的メモリ下限が既定の 512MB。** `Ensure-ControlNode.ps1` が VM 作成時に
   `Set-VMMemory -DynamicMemoryEnabled $true` を**下限指定なし**で呼んでいた。アイドルが続くと
   バルーンドライバがメモリを 512MB まで回収する。その状態で scp + ansible-playbook (Python +
   pywinrm) が走ると VM がスラッシュ (実質ストール) し、SSH の転送が固まる。
   - 初回 (VM 作成直後) は assigned が大きく問題が出にくいが、**再実行時はアイドルで縮んだ後**に
     当たるため再現する → 「冪等再実行だけ固まる」という紛らわしい出方になる。
2. **SSH に keepalive が無かった。** `Run-OnControl.ps1` の ssh/scp は `ConnectTimeout=8` だけで、
   **接続確立後**に相手が無応答になっても切断しない (`ServerAliveInterval` 未設定)。だから
   ストールした転送が**永久に待ち続け**、bootstrap 全体がハングした (エラーにすらならない)。

## 対策

- **メモリ下限を明示** (`Ensure-ControlNode.ps1`)。VM 作成時 (停止中) に下限/上限を固定する:
  ```powershell
  Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
      -MinimumBytes 2GB -StartupBytes ([int64]$MemoryGB*1GB) -MaximumBytes ([int64]$MemoryGB*1GB)
  ```
  下限 2GB を割らないので、アイドル後でも scp/ansible が回せる。
  (注: 動的メモリの Min/Max は**実行中は変更不可** — Min は減少のみ・Max は増加のみ。既存 VM を
  直す場合は一度 `Stop-VM` してから設定する。)
- **SSH keepalive を追加** (`Run-OnControl.ps1` の ssh/scp 共通オプション):
  ```
  -o ServerAliveInterval=15 -o ServerAliveCountMax=8
  ```
  確立後にストールしたら 15s×8=120s で切断 → scp/ssh が非ゼロ終了 → `Invoke-Ansible` の `throw` が
  発火し、**ハングではなく fail-fast** になる (ログに失敗が出るので原因を追える)。

## 教訓 / 汎用ノウハウ

- **動的メモリの下限は必ず明示する。** 「常駐して仕事をする」VM (オーケストレータ/CI ランナー等) を
  既定の動的メモリ (下限 512MB) で作ると、アイドル→縮小→次の仕事で枯渇、という時限爆弾になる。
  初回は通って**再実行で初めて出る**ため、冪等性テストまでやらないと気づけない。
- **リモート実行の配管には必ず keepalive を入れる。** `ConnectTimeout` は「繋がるまで」しか守らない。
  繋がった後に相手が固まるケース (メモリ枯渇・パニック・NW 断) は `ServerAliveInterval` /
  `ServerAliveCountMax` でしか救えない。これが無いと 1 台の不調が**自動化全体の無限ハング**になる。
- **「初回は成功、再実行でハング」は資源枯渇 (メモリ/ディスク/ハンドル) を疑う。** 状態が
  時間経過で変わる (バルーン縮小・キャッシュ増大) のが典型パターン。
