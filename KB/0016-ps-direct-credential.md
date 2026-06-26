# 0016 — PowerShell Direct は -Credential 必須（非対話で無言ハング）

## 症状

L0 ホストから L1/L2 の Windows ゲストへ PowerShell Direct（`Invoke-Command -VMName` /
`Enter-PSSession -VMName`）を叩くと、**何も返さず固まる**。SSH 越し・スクリプト経由など
**非対話セッションで顕著**で、タイムアウトするまでプロンプトも返らない。

```powershell
# これがハングする（資格情報を渡していない）
Invoke-Command -VMName "nested-lab-01" -ScriptBlock { hostname }
```

## 原因

PowerShell Direct は VMBus 経由でゲストに入るが、**ホストの現在のトークンをゲストに引き継げない**
（ゲストはワークグループで、ホストとは信頼関係がない）。そのため `-Credential` を省くと
**ゲスト用の資格情報を対話プロンプトで要求**する。非対話シェル（SSH の `powershell -EncodedCommand`、
scheduler、CI 等）には入力する標準入力が無いので、その隠れたプロンプト待ちで**永久にブロック**する。
「PS Direct が壊れている／使えない」と誤診しやすいが、実際は資格情報待ちなだけ。

## 対策

**必ず `-Credential` を明示する。** ゲストのローカル管理者資格情報で `PSCredential` を組み立てて渡す。

```powershell
$pw   = ConvertTo-SecureString 'P@ssw0rd-Lab-Change!' -AsPlainText -Force   # golden 既定のlab用
$cred = New-Object System.Management.Automation.PSCredential('Administrator', $pw)
Invoke-Command -VMName 'nested-lab-01' -Credential $cred -ScriptBlock { hostname }   # => nested-lab-01
```

- アカウント名は `Administrator` でも `<computername>\Administrator` でも可（両方確認済み）。
- パスワードの正本は golden 既定（リポジトリ `CLAUDE.md` / `secrets.example.yml`）。lab 用の使い捨て前提。
- 自動化では資格情報をハードコードせず、`build/host-cred.json` 等の確立済みの受け渡しに合わせる。

## 教訓 / 汎用ノウハウ

- **非対話で固まったら、まず「隠れた対話プロンプト待ち」を疑う。** PS Direct / `Get-Credential` /
  `Read-Host` 等は、TTY が無い環境で無言ハングする。タイムアウト＝即「機能が壊れた」ではない。
- PowerShell Direct は対象に IP も WinRM も不要で届く強力な経路だが、**認証だけは肩代わりしてくれない**。
  これが「Ansible（IP+WinRM 前提）が使えない段でも PS Direct なら届く」の裏返しの制約。
