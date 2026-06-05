#Requires -Version 5.1
<#
.SYNOPSIS
  本線 (制御 VM -> WinRM -> ホスト Hyper-V) 用の専用ローカル管理者を冪等に用意する。

.DESCRIPTION
  既存の Administrator パスワードに触れず、nestedlab 専用のローカル
  Administrators ユーザーを作成/収束する。WinRM(NTLM) で使う。
  パスワードはランダム生成し、build/ にローカル限定で保存 (gitignore 済み)。
  -Remove でユーザーと資格情報ファイルを削除できる。

.NOTES
  これは「ラボ用」割り切り。資格情報ファイルは平文 (build 配下/.gitignore)。
  本番運用では Vault 管理 + gMSA 等へ移行する余地を docs に記載。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$User = "nestedlab-svc",
    [switch]$Remove
)
$ErrorActionPreference = "Stop"
function Log($m){ Write-Host "  [svc-user] $m" -ForegroundColor DarkCyan }
$credDir = Join-Path $RepoRoot "build"
$credFile = Join-Path $credDir "host-cred.json"
New-Item -ItemType Directory -Force -Path $credDir | Out-Null

if ($Remove) {
    if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $User; Log "ユーザー削除: $User" }
    if (Test-Path $credFile) { Remove-Item $credFile -Force; Log "資格情報ファイル削除" }
    exit 0
}

# パスワード生成 (英大小+数字+記号で 20 文字)
function New-RandomPassword {
    $sets = @(
        (65..90  | ForEach-Object {[char]$_}),   # A-Z
        (97..122 | ForEach-Object {[char]$_}),   # a-z
        (48..57  | ForEach-Object {[char]$_}),   # 0-9
        ('!','@','#','%','^','*','-','_','=','+') )
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 64; $rng.GetBytes($bytes)
    $chars = for ($i=0; $i -lt 20; $i++) {
        $set = $sets[$bytes[$i] % $sets.Count]
        $set[ $bytes[$i+20] % $set.Count ]
    }
    -join $chars
}

$existing = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
$pw = New-RandomPassword
$securePw = ConvertTo-SecureString $pw -AsPlainText -Force

if (-not $existing) {
    New-LocalUser -Name $User -Password $securePw -FullName "Nested Lab Service" `
        -Description "nestedhyper-v WinRM service account" -PasswordNeverExpires:$true -AccountNeverExpires:$true | Out-Null
    Log "作成: $User"
} else {
    Set-LocalUser -Name $User -Password $securePw -PasswordNeverExpires:$true
    Log "既存ユーザーのパスワードを更新: $User"
}

# Administrators グループへ追加 (冪等)
$grp = (Get-LocalGroup -SID "S-1-5-32-544").Name   # ローカライズ対応
$isMember = Get-LocalGroupMember -Group $grp -Member $User -ErrorAction SilentlyContinue
if (-not $isMember) { Add-LocalGroupMember -Group $grp -Member $User; Log "$grp に追加" }

# WinRM(NTLM) はローカルアカウントでも可。UAC リモート制限の回避は不要 (Administrators かつ NTLM)。
# 資格情報を build に保存 (gitignore)
[ordered]@{ user = $User; password = $pw; host_addr = "10.20.0.1" } |
    ConvertTo-Json | Out-File -FilePath $credFile -Encoding utf8
Log "資格情報を保存: $credFile"
exit 0
