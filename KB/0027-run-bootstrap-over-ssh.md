# 0027 — bootstrap を SSH 越し (非対話) で流すと無限ハングする / 途中で殺される

## 症状

ホストのコンソールで実行すれば通る `bootstrap.ps1` が、**SSH 越しに流したときだけ**次の行で
止まったまま進まない。CPU も消費せず、エラーも出ない。

```
==> 本線疎通確認: 制御 VM -> WinRM -> ホスト Hyper-V
  [ansible] ansible/ と確定モデルを制御 VM へ同期
Warning: Permanently added '10.20.0.10' (ED25519) to the list of known hosts.
   ← ここから先に進まない
```

ホスト側には `ssh.exe` が 1 つ残る (CPU ほぼ 0)。制御 VM 側は健全で、手で
`ssh labadmin@10.20.0.10 "echo ok"` を叩くと**それも同じように固まる**。制御 VM を作り直しても
再現するため「制御 VM が壊れた」と誤診しやすい (KB/0011 と症状がそっくりだが原因は別)。

## 原因 (3 つある。どれか 1 つでも踏むと止まる)

1. **`ssh` は既定で標準入力を読む。** 自動化チェーンの中で起動された `ssh` は親から stdin を継承する。
   SSH セッション越しの非対話実行では、その stdin が**永久に閉じない**ため、`ssh` は入力待ちの
   まま止まる。keepalive (`ServerAliveInterval`) は**接続確立後**にしか効かず、
   `ConnectTimeout` は「繋がるまで」しか守らないので、どちらもこれを救えない。
2. **SSH セッションが閉じると子プロセスが道連れになる。** Windows OpenSSH はセッション終了時に
   子プロセスツリーを殺す。`Start-Process` で切り離したつもりでも、ssh を抜けた瞬間に消える。
3. **タスクスケジューラで SYSTEM として流すと、ユーザー配下にインストールされた Python が
   見えない。** `bootstrap.ps1` のプリフライトが「Python (pyyaml + jsonschema) が見つかりません」で
   落ちる。Python が `C:\Users\<user>\AppData\Local\Programs\Python\...` にある場合の典型。

## 対策

**ラッパースクリプトを 1 枚置き、タスクスケジューラから実行ユーザーで流す。**

```powershell
# build\run-bootstrap.ps1 (例)
$root = 'D:\hyperv-nestlab'
$log  = "$root\build\bootstrap.log"
$nul  = "$root\build\empty-stdin.txt"
Set-Content -Path $nul -Value '' -NoNewline          # 空ファイル = 即 EOF
$p = Start-Process -FilePath 'C:\Program Files\PowerShell\7\pwsh.exe' `
  -ArgumentList '-NoProfile','-File',"$root\bootstrap.ps1",'-L1','l1\standard-host.yml','-L2','l2\arc-demo.yml' `
  -WorkingDirectory $root -NoNewWindow -PassThru `
  -RedirectStandardOutput $log -RedirectStandardError "$root\build\bootstrap.err" `
  -RedirectStandardInput $nul                          # ← 1. の対策 (子孫の ssh が stdin で止まらない)
$p.WaitForExit()
"EXITCODE=$($p.ExitCode)" | Add-Content $log
```

```powershell
# 2. と 3. の対策: セッションから切り離し、かつ「Python が見えるユーザー」で走らせる
$action = New-ScheduledTaskAction -Execute 'C:\Program Files\PowerShell\7\pwsh.exe' `
    -Argument '-NoProfile -File D:\hyperv-nestlab\build\run-bootstrap.ps1' -WorkingDirectory 'D:\hyperv-nestlab'
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\Administrator" -LogonType S4U -RunLevel Highest
Register-ScheduledTask -TaskName 'nestlab-bootstrap' -Action $action -Principal $principal `
    -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4))
Start-ScheduledTask -TaskName 'nestlab-bootstrap'
```

進捗は `Get-Content build\bootstrap.log -Tail 20 -Encoding UTF8` で読む
(`-Encoding UTF8` を付けないと日本語が cp932 として化ける)。

補足: 出力を `bootstrap.ps1 *> $log` のように **PowerShell のリダイレクトだけで**受けると、
`ansible-playbook` など**子プロセスの出力は捕まらない** (PowerShell のストリームではなく、
継承したコンソールハンドルへ出るため)。上記のように `Start-Process` の
`-RedirectStandardOutput` で**本物のファイルハンドル**を渡すこと。

## 教訓 / 汎用ノウハウ

- **自動化の中で使う `ssh` には `-n` (または stdin を /dev/null・空ファイルへ) を必ず付ける。**
  「ssh が黙って止まる」の最頻出原因。タイムアウト系のオプションでは救えないので、
  ハングの切り分けで真っ先に疑う。
- **「対話で実行すると通るが、自動実行だと止まる」は、まず stdin・端末・実行ユーザーを疑う。**
  ロジックではなく実行文脈の差なので、コードをいくら読んでも原因は出てこない。
- **ユーザー配下にインストールしたランタイムは SYSTEM から見えない。** CI やスケジューラで
  「ローカルでは動くのに見つからない」と言われたら、まず実行アカウントを確認する。
- **リダイレクトは「言語のストリーム」ではなく「プロセスのハンドル」で行う。** 子プロセスの
  出力まで確実に捕まえたいときは、シェル/言語のリダイレクト構文では足りないことがある。
