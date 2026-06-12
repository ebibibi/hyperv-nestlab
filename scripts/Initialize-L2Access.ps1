#Requires -Version 5.1
<#
.SYNOPSIS
  Windows L2 ゲストを「制御 VM の Ansible から到達できる」最小状態へ収束させる。
  (静的 IP / 改名 / WinRM / CredSSP サーバ有効化) を PowerShell Direct で焼き込む。

.DESCRIPTION
  LabNAT には DHCP が無いため、作成直後の Windows L2 は IP も WinRM も無く、制御 VM から
  到達できない。そこで「最小ブートストラップだけ」を VMBus 経由の PowerShell Direct で行い、
  以降の本格構成 (ドメイン昇格/参加・クラスタ・S2D) は Ansible (制御VM→WinRM→L2) に委ねる。

  なぜ CredSSP も有効化するか:
    AD/クラスタの特権操作は L2 から DC へ二段ホップ (ネットワークログオンの委譲) を要する。
    NTLM では委譲できず "アクセス拒否" になる。CredSSP を有効化しておくと Ansible が委譲付きで
    実行でき、New-Cluster / VCO 作成等が WinRM 経由でも通る。

  冪等: 目的 IP が既にあれば設定しない / 改名済みならしない / WinRM・CredSSP は収束のみ。
  Linux L2 は cloud-init が IP/SSH を与えるため対象外 (本スクリプトは Windows L2 のみ)。

.PARAMETER ModelPath  確定モデル (既定 build/resolved.json)
.PARAMETER L1Name     L1 VM 名 (既定 model l1.name)
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ModelPath,
    [string]$L1Name,
    [string]$L1User = "Administrator",
    [string]$L1Password = "P@ssw0rd-Lab-Change!",
    [string]$GuestPassword = "P@ssw0rd-Lab-Change!"
)
$ErrorActionPreference = "Stop"
function Log($m){ Write-Host "  [l2access] $m" -ForegroundColor DarkCyan }
if (-not $ModelPath) { $ModelPath = Join-Path $RepoRoot "build\resolved.json" }
$cfg = Get-Content $ModelPath -Raw | ConvertFrom-Json
if (-not $L1Name) { $L1Name = $cfg.l1.name }
$prefix = [int]($cfg.l1.nat.subnet -split '/')[1]
$netbios = if ($cfg.domain) { $cfg.domain.netbios } else { $null }   # 昇格済み DC への再接続用

# Windows L2 のみ。DNS は (ドメインがあれば) DC、無ければ NAT GW。
$winVms = @($cfg.vms | Where-Object { $_.os -notmatch 'ubuntu|debian|linux|rocky|alma' })
if (-not $winVms) { Log "Windows L2 はありません。何もしません。"; exit 0 }

$targets = @()
foreach ($vm in $winVms) {
    $targets += [pscustomobject]@{
        Name = $vm.name
        Ip   = $vm.nics[0].ip
        Gw   = $vm.nics[0].gw
        Dns  = if ($vm.nics[0].dns) { $vm.nics[0].dns } else { $vm.nics[0].gw }
    }
}
$targetJson = $targets | ConvertTo-Json -Compress -Depth 5
if ($targets.Count -eq 1) { $targetJson = "[$targetJson]" }  # 1件でも配列に

$l1cred = New-Object System.Management.Automation.PSCredential($L1User,(ConvertTo-SecureString $L1Password -AsPlainText -Force))
Log "L1 ($L1Name) への PowerShell Direct セッションを確立"
$l1 = New-PSSession -VMName $L1Name -Credential $l1cred
try {
    $result = Invoke-Command -Session $l1 -ScriptBlock {
        param($targetJson,$prefix,$guestPw,$netbios)
        $ErrorActionPreference = 'Stop'
        $log = New-Object System.Collections.ArrayList
        function W($m){ [void]$log.Add($m) }
        $targets = $targetJson | ConvertFrom-Json
        $localCred = New-Object System.Management.Automation.PSCredential('Administrator',(ConvertTo-SecureString $guestPw -AsPlainText -Force))
        # 冪等再実行で対象が既に昇格済み DC だとローカル管理者が消えているため、ドメイン管理者でも試す。
        $creds = @($localCred)
        if ($netbios) { $creds += (New-Object System.Management.Automation.PSCredential("$netbios\Administrator",(ConvertTo-SecureString $guestPw -AsPlainText -Force))) }

        function Connect-Guest { param($vm,$credList,$timeoutSec=900)
            $dl=(Get-Date).AddSeconds($timeoutSec)
            while((Get-Date) -lt $dl){
                foreach ($c in $credList) {
                    try { return New-PSSession -VMName $vm -Credential $c -ErrorAction Stop } catch {}
                }
                Start-Sleep 10
            }
            throw "guest $vm へ PS Direct 接続できませんでした (timeout)"
        }

        foreach ($t in $targets) {
            $name=$t.Name; $ip=$t.Ip; $gw=$t.Gw; $dns=$t.Dns
            W "L2 ${name}: OOBE 完了/管理者ログオンを待機"
            $s = Connect-Guest $name $creds 900
            try {
                $changed = Invoke-Command -Session $s -ScriptBlock {
                    param($ip,$gw,$pfx,$dns,$name)
                    $ErrorActionPreference='Stop'
                    $out=@(); $reboot=$false
                    $a = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
                    if (-not $a) { for($i=0;$i -lt 15 -and -not $a;$i++){ Start-Sleep 2; $a=Get-NetAdapter|Where-Object Status -eq 'Up'|Select-Object -First 1 } }
                    if (-not $a) { throw "Up な NIC なし" }
                    $idx=$a.ifIndex
                    if (-not (Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -EA SilentlyContinue | Where-Object IPAddress -eq $ip)) {
                        Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled -EA SilentlyContinue
                        Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -EA SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Remove-NetIPAddress -Confirm:$false -EA SilentlyContinue
                        Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Remove-NetRoute -Confirm:$false -EA SilentlyContinue
                        New-NetIPAddress -InterfaceIndex $idx -IPAddress $ip -PrefixLength $pfx -DefaultGateway $gw | Out-Null
                        $out += "IP $ip/$pfx gw $gw"
                    }
                    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dns -EA SilentlyContinue
                    Set-NetConnectionProfile -InterfaceIndex $idx -NetworkCategory Private -EA SilentlyContinue
                    # WinRM + FW + ローカル管理者のリモートトークン
                    Set-Service WinRM -StartupType Automatic; if ((Get-Service WinRM).Status -ne 'Running'){ Start-Service WinRM }
                    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
                    if (-not (Get-NetFirewallRule -Name 'NestedLab-WinRM-In' -EA SilentlyContinue)) {
                        New-NetFirewallRule -Name 'NestedLab-WinRM-In' -DisplayName 'NestedLab WinRM' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -Profile Any | Out-Null
                    }
                    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
                    # CredSSP サーバ (Ansible の二段ホップ委譲用)
                    try { Enable-WSManCredSSP -Role Server -Force | Out-Null; $out += "CredSSP server" } catch {}
                    # RDP 有効化 (検証環境向け / 冪等)。NLA 維持。
                    if ((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -EA SilentlyContinue).fDenyTSConnections -ne 0) {
                        Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
                        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -EA SilentlyContinue
                        Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1 -EA SilentlyContinue
                        $out += "RDP"
                    }
                    # 改名 (AD/クラスタ用)。要再起動。
                    if ($env:COMPUTERNAME -ne $name) { Rename-Computer -NewName $name -Force; $out += "rename->$name"; $reboot=$true }
                    [pscustomobject]@{ out=$out; reboot=$reboot }
                } -ArgumentList $ip,$gw,$prefix,$dns,$name
            } finally { Remove-PSSession $s }
            W "L2 ${name}: $($changed.out -join ' / ')"
            if ($changed.reboot) {
                W "L2 ${name}: 改名適用のため再起動 (L1 から Restart-VM)"
                Restart-VM -Name $name -Force
                Start-Sleep 25
                # 再起動後に到達確認
                $s2 = Connect-Guest $name $creds 600; Remove-PSSession $s2
                W "L2 ${name}: 再起動後ログオン確認 OK"
            }
        }
        return $log
    } -ArgumentList $targetJson,$prefix,$GuestPassword,$netbios
    $result | ForEach-Object { Log $_ }
}
finally { if ($l1) { Remove-PSSession $l1 } }
Log "L2 アクセス初期化 完了"
exit 0
