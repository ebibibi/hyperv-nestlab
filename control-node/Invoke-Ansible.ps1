#Requires -Version 5.1
<#
.SYNOPSIS
  ホストから制御 VM を駆動し、Ansible playbook を実行する配管 (本線)。

.DESCRIPTION
  1. ansible/ ディレクトリと build/resolved.json を制御 VM へ scp 同期
  2. L0(ホスト) WinRM 資格情報を環境変数で制御 VM 側へ受け渡し
  3. 制御 VM 上で ansible-playbook を実行 (制御 VM -> WinRM -> ホスト Hyper-V)

  資格情報は build/host-cred.json (Ensure-LabServiceUser.ps1 が生成) を既定で使用。
  ホストの実 IP は制御 VM から見た CtrlNAT ゲートウェイ (既定 10.20.0.1)。

.EXAMPLE
  Invoke-Ansible.ps1 -RepoRoot C:\...\nestedhyper-v -Model build\resolved.json -Playbook ping_l0.yml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Model,
    [string]$Playbook = "site.yml",
    [string]$Secrets,
    [securestring]$VaultPassword,
    [string]$Ip = "10.20.0.10",
    [string]$User = "labadmin",
    [string]$CredFile,
    [string]$L1Addr = "10.20.0.20",
    [string]$L1User = "Administrator",
    [string]$L1Password
)
$ErrorActionPreference = "Stop"
$runner = Join-Path $RepoRoot "scripts\ctrl\Run-OnControl.ps1"
function Log($m){ Write-Host "  [ansible] $m" -ForegroundColor DarkCyan }

# 制御 VM を作り直すと SSH ホスト鍵が変わり、既存の known_hosts と衝突して
# 「REMOTE HOST IDENTIFICATION HAS CHANGED」警告が大量に出る (pubkey 認証自体は通るが煩い)。
# StrictHostKeyChecking=no で都度ピン留めし直すため、古いエントリは消しておく。
$knownHosts = Join-Path $env:TEMP 'nl_known_ctrl'
if (Test-Path $knownHosts) { Remove-Item $knownHosts -Force -ErrorAction SilentlyContinue }

# --- ホスト資格情報 ---
if (-not $CredFile) { $CredFile = Join-Path $RepoRoot "build\host-cred.json" }
$hostUser = $env:HYPERV_USER; $hostPass = $env:HYPERV_PASSWORD; $hostAddr = "10.20.0.1"
if ((-not $hostUser -or -not $hostPass) -and (Test-Path $CredFile)) {
    $c = Get-Content $CredFile -Raw | ConvertFrom-Json
    $hostUser = $c.user; $hostPass = $c.password
    if ($c.host_addr) { $hostAddr = $c.host_addr }
}
if (-not $hostUser -or -not $hostPass) {
    throw "ホスト WinRM 資格情報がありません。Ensure-LabServiceUser.ps1 を実行するか HYPERV_USER/HYPERV_PASSWORD を設定してください。"
}

# --- 同期 (ansible ディレクトリ + 確定モデル) ---
Log "ansible/ と確定モデルを制御 VM へ同期"
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Command "mkdir -p ~/nestedlab/build"
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Push @("ansible::/home/$User/nestedlab/")
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Push @("$Model::/home/$User/nestedlab/build/resolved.json")
# scp は実行ビットを落とすため、動的インベントリへ +x を付与
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Command "chmod +x ~/nestedlab/ansible/inventory/resolved_inventory.py"
# scp で作られるディレクトリは world-writable になり、Ansible が
# 「world writable directory」として ansible.cfg (roles_path 等) を無視してしまう。
# group/other の書き込み権を落として ansible.cfg を有効化する。
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Command "chmod -R go-w ~/nestedlab/ansible"
# Windows で clone すると git autocrlf によりテキストが CRLF になり、Linux 側で実行/解釈すると
# 壊れる (例: inventory スクリプトの shebang '#!/usr/bin/env python3\r' → No such file)。
# clone の状態に依存しないよう、同期後に Linux 側で CR を除去して正規化する。
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Command "find ~/nestedlab -type f \( -name '*.py' -o -name '*.yml' -o -name '*.yaml' -o -name '*.cfg' -o -name '*.ini' -o -name '*.sh' -o -name '*.j2' -o -name '*.json' \) -exec sed -i 's/\r`$//' {} +"

# --- リモート実行コマンド組み立て ---
# 環境変数で資格情報/接続情報を渡す。playbook はリポジトリ相対。
$remoteCmd = @"
set -e
cd ~/nestedlab/ansible
export ANSIBLE_CONFIG=~/nestedlab/ansible/ansible.cfg
export ANSIBLE_ROLES_PATH=~/nestedlab/ansible/roles
export RESOLVED_MODEL=~/nestedlab/build/resolved.json
export HYPERV_HOST=hyperv-host
export HYPERV_ADDR='$hostAddr'
export HYPERV_USER='$hostUser'
export HYPERV_PASSWORD='$hostPass'
export L1_ADDR='$L1Addr'
export L1_USER='$L1User'
export L1_PASSWORD='$L1Password'
export ANSIBLE_HOST_KEY_CHECKING=False
ansible-playbook -i inventory/resolved_inventory.py playbooks/$Playbook
"@
# この .ps1 自体が CRLF で clone されると here-string も CRLF になり、bash に渡すと
# 「set: -<CR>: invalid option」等で壊れる。ファイルの改行コードに依存せず LF へ正規化する。
$remoteCmd = $remoteCmd -replace "`r`n", "`n" -replace "`r", "`n"

Log "制御 VM 上で ansible-playbook playbooks/$Playbook を実行"
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Command $remoteCmd
$rc = $LASTEXITCODE
if ($rc -ne 0) { throw "ansible-playbook が失敗しました (exit $rc)。" }
Log "完了"
exit 0
