#Requires -Version 5.1
<#
.SYNOPSIS
  L0 物理ホストの WinRM を、制御 VM (ドメイン外クライアント) から Ansible で
  操作できる状態へ冪等に収束させる。

.DESCRIPTION
  本線 (制御 VM -> WinRM -> ホストの Hyper-V) に必要な最小設定:
    - WinRM サービス起動 + 自動起動
    - HTTP リスナー (5985) ※ NTLM はペイロードを暗号化するため LAN ラボでは HTTP で可
    - NTLM 認証許可
    - ファイアウォール 5985 許可 (CtrlNAT サブネットからのみに絞る)
  すべて「現状確認 -> 必要時のみ変更」で冪等。

  注意: bootstrap はホスト上で管理者権限で動く前提。ここで開けるのは制御 VM サブネット
        (既定 10.20.0.0/24) からのみ。
#>
[CmdletBinding()]
param(
    [string]$CtrlSubnet = "10.20.0.0/24"
)
$ErrorActionPreference = "Stop"
function Log($m){ Write-Host "  [winrm] $m" -ForegroundColor DarkCyan }
$changed = $false

# サービス
$svc = Get-Service WinRM
if ($svc.StartType -ne 'Automatic') { Set-Service WinRM -StartupType Automatic; $changed = $true }
if ($svc.Status -ne 'Running') { Start-Service WinRM; $changed = $true }

# WinRM 基本構成 (未構成なら quickconfig 相当)
if (-not (Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue |
          Where-Object { $_.Keys -contains "Transport=HTTP" })) {
    Log "HTTP リスナーを作成"
    New-Item -Path WSMan:\localhost\Listener -Transport HTTP -Address * -Force | Out-Null
    $changed = $true
}

# NTLM 認証を許可 (既定で有効だが収束させる)
$auth = Get-Item WSMan:\localhost\Service\Auth\Negotiate
if ($auth.Value -ne $true) { Set-Item WSMan:\localhost\Service\Auth\Negotiate -Value $true; $changed = $true }

# ファイアウォール: 制御 VM サブネットからのみ 5985 を許可
$ruleName = "NestedLab-WinRM-HTTP-In"
$rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if (-not $rule) {
    Log "ファイアウォール規則を作成 ($CtrlSubnet -> 5985)"
    New-NetFirewallRule -Name $ruleName -DisplayName "Nested Lab WinRM HTTP (control VM)" `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 `
        -RemoteAddress $CtrlSubnet -Profile Any | Out-Null
    $changed = $true
} else {
    $cur = ($rule | Get-NetFirewallAddressFilter).RemoteAddress
    if ($cur -ne $CtrlSubnet) { Set-NetFirewallRule -Name $ruleName -RemoteAddress $CtrlSubnet; $changed = $true }
}

if ($changed) { Log "WinRM を収束させました (変更あり)" } else { Log "WinRM は既に期待状態 (no-change)" }
exit 0
