#Requires -Version 5.1
<#
.SYNOPSIS
  L1 (Nested ホスト) を制御 VM から WinRM で操作できる状態へ収束させる。
  具体的には L1 を CtrlNAT に接続し、PowerShell Direct で L1 内に静的 IP と
  WinRM を構成する。

.DESCRIPTION
  制御 VM (Ansible) は CtrlNAT (10.20.0.0/24) 上の WinRM で L1 (10.20.0.20) を
  叩く。しかし L1 は golden から作られた直後で「CtrlNAT に未接続 / 静的 IP 未設定 /
  WinRM 未構成」のため、そのままでは到達できない (No route to host)。CtrlNAT には
  DHCP が無いので、ネットワーク未確立の段階でも届く PowerShell Direct (VMBus) で
  L1 内に静的 IP と WinRM を焼き込む。

  冪等:
    L0 側 : CtrlNAT を確保し、L1 の NIC を CtrlNAT へ接続 (既に接続済みなら何もしない)。
    L1 側 : 目的の静的 IP が無ければ設定、WinRM が未構成なら有効化。

  L1 (1段目/ホスト) の言語は英語固定方針のため、ここでは言語に依存しない API のみ使う。

.PARAMETER VMName        L1 VM 名 (既定: build/resolved.json の l1.name)
.PARAMETER Switch        L1 を接続する L0 スイッチ (既定 CtrlNAT)
.PARAMETER Subnet/HostIp CtrlNAT のサブネットとゲートウェイ (L0 側 IP)
.PARAMETER IPCidr        L1 に割り当てる静的 IP (既定 10.20.0.20/24)
.PARAMETER L1User/L1Password  PowerShell Direct 資格情報 (既定: golden の管理者)
#>
[CmdletBinding()]
param(
    [string]$VMName,
    [string]$Switch   = "CtrlNAT",
    [string]$Subnet   = "10.20.0.0/24",
    [string]$HostIp   = "10.20.0.1",
    [string]$IPCidr   = "10.20.0.20/24",
    [string[]]$Dns    = @("1.1.1.1","8.8.8.8"),
    [string]$L1User   = "Administrator",
    [string]$L1Password = "P@ssw0rd-Lab-Change!",
    [int]$ReadyTimeoutSec = 300
)
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot "scripts\HyperVLab.psm1.ps1")
function Log($m){ Write-Host "  [l1net] $m" -ForegroundColor DarkCyan }

if (-not $VMName) {
    $model = Join-Path $RepoRoot "build\resolved.json"
    if (Test-Path $model) { $VMName = (Get-Content $model -Raw | ConvertFrom-Json).l1.name }
    if (-not $VMName) { throw "VMName を解決できません。-VMName を指定してください。" }
}
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { throw "L1 VM '$VMName' が存在しません。" }

# --- L0: CtrlNAT を確保し L1 を接続 ---
Ensure-NatNetwork -SwitchName $Switch -Subnet $Subnet -HostIp $HostIp | Out-Null
Log "CtrlNAT ($Subnet, gw $HostIp) を確保"

$na = Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1
if (-not $na) { throw "L1 に仮想 NIC がありません。" }
if ($na.SwitchName -ne $Switch) {
    Log "L1 の NIC を $Switch へ接続 (現在: $($na.SwitchName))"
    Connect-VMNetworkAdapter -VMNetworkAdapter $na -SwitchName $Switch
} else {
    Log "L1 の NIC は既に $Switch に接続済み"
}
# Nested ホストは MAC スプーフィング必須 (L2 のトラフィックを通すため)
Get-VMNetworkAdapter -VMName $VMName | Where-Object { $_.MacAddressSpoofing -ne 'On' } |
    Set-VMNetworkAdapter -MacAddressSpoofing On

# CtrlNAT アップリンクの MAC を L0 側から確定し、L1 内でこのアダプタだけを対象にする。
# 「最初の Up な NIC」で選ぶと setup_l1 が作る内部スイッチ vEthernet(LabNAT) が出来た後の
# 再実行で誤選択し、制御 IP を別アダプタへ載せ替えてしまう (KB/0012)。
$mac = (Get-VMNetworkAdapter -VMName $VMName | Where-Object { $_.SwitchName -eq $Switch } | Select-Object -First 1).MacAddress
if (-not $mac -or $mac -eq '000000000000') { throw "CtrlNAT アップリンクの MAC を確定できません ($Switch)。" }

if ($vm.State -ne 'Running') { Log "L1 を起動"; Start-VM -Name $VMName | Out-Null }

# --- L1: PowerShell Direct で静的 IP + WinRM を構成 ---
$ip  = $IPCidr.Split('/')[0]
$pfx = [int]($IPCidr.Split('/')[1])
$cred = New-Object System.Management.Automation.PSCredential($L1User, (ConvertTo-SecureString $L1Password -AsPlainText -Force))
Log "L1 への PowerShell Direct セッションを待機 (最大 ${ReadyTimeoutSec}s)"
$deadline = (Get-Date).AddSeconds($ReadyTimeoutSec); $session = $null
while (-not $session -and (Get-Date) -lt $deadline) {
    try { $session = New-PSSession -VMName $VMName -Credential $cred -ErrorAction Stop }
    catch { Start-Sleep -Seconds 8 }
}
if (-not $session) { throw "L1 へ PowerShell Direct セッションを張れませんでした (起動/資格情報を確認)。" }

try {
    $result = Invoke-Command -Session $session -ScriptBlock {
        param($Ip,$Pfx,$Gw,$Dns,$Mac)
        $ErrorActionPreference = 'Stop'
        $out = @()

        # CtrlNAT アップリンクを MAC で一意特定する (KB/0012)。
        # 「最初の Up な NIC」だと、setup_l1 が作る内部スイッチ vEthernet(LabNAT) が出来た後の
        # 再実行で誤選択し、制御 IP を LabNAT 側に載せ替えて ARP 応答が割れ「No route to host」に
        # なる。L0 側 L1 仮想 NIC (CtrlNAT 接続) の MAC と一致するアダプタのみを対象にする。
        $want = ($Mac -replace '[-:]','').ToUpper()
        $a = $null
        for ($i=0; $i -lt 15 -and -not $a; $i++) {
            $a = Get-NetAdapter -ErrorAction SilentlyContinue |
                 Where-Object { ($_.MacAddress -replace '[-:]','').ToUpper() -eq $want -and $_.Status -eq 'Up' } |
                 Select-Object -First 1
            if (-not $a) { Start-Sleep 2 }
        }
        if (-not $a) { throw "L1 内に CtrlNAT アップリンク (MAC $want) が見つかりません。" }
        $idx = $a.ifIndex

        # 他アダプタに紛れ込んだ制御 IP を剥がす。過去の誤選択で vEthernet(LabNAT) 等に
        # 載っていると ARP 応答が割れて到達不能になるため、正しいアダプタ以外から除去する。
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $Ip -and $_.InterfaceIndex -ne $idx } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        # 静的 IP (冪等)
        $has = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $Ip }
        if (-not $has) {
            # 既存の自動 IP / 既定ルートを掃除して静的化
            Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -ErrorAction SilentlyContinue
            Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $idx -IPAddress $Ip -PrefixLength $Pfx -DefaultGateway $Gw | Out-Null
            $out += "static IP $Ip/$Pfx gw $Gw を $($a.Name) に設定"
        } else {
            $out += "IP $Ip は設定済み"
        }
        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $Dns -ErrorAction SilentlyContinue

        # WinRM のファイアウォール規則を効かせるためプロファイルを Private に
        Set-NetConnectionProfile -InterfaceIndex $idx -NetworkCategory Private -ErrorAction SilentlyContinue

        # WinRM を有効化 (冪等)
        Set-Service WinRM -StartupType Automatic
        if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }
        Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
        # 制御 VM サブネットからの 5985 を全プロファイルで許可 (明示規則)
        $rn = 'NestedLab-WinRM-In'
        if (-not (Get-NetFirewallRule -Name $rn -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name $rn -DisplayName 'NestedLab WinRM HTTP (control VM)' `
                -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -Profile Any | Out-Null
        }
        # ローカル管理者 (ビルトイン Administrator) のリモート昇格トークンを許可
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        New-ItemProperty -Path $key -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
        $out += "WinRM 有効化 + FW 5985 (Any) + LocalAccountTokenFilterPolicy=1"

        $out += ("IP 確認: " + ((Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 | ForEach-Object { $_.IPAddress }) -join ','))
        $out
    } -ArgumentList $ip,$pfx,$HostIp,$Dns,$mac

    $result | ForEach-Object { Log $_ }
}
finally {
    if ($session) { Remove-PSSession $session }
}
Log "L1 ネットワーク/WinRM 構成 完了"
exit 0
