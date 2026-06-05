#Requires -Version 5.1
<#
.SYNOPSIS
  L2 上に Active Directory フォレストを構築し、メンバサーバをドメイン参加させる。

.DESCRIPTION
  L2 VM は LabNAT 内に隔離され (L1内NAT自己完結)、制御VMから直接届かない。さらに
  AD 昇格/参加は再起動を伴う。そこで本スクリプトは L1 を踏み台に「二段 PowerShell Direct」
  (L0 -> L1 -> 各 L2) でゲスト内を直接操作する。PS Direct は VMBus 経由で物理NWに依存せず、
  再起動をまたぐ再接続も確実に扱えるため、隔離ゲストの ID ブートストラップに最適 (原則①)。

  確定モデル(resolved.json)を入力に:
    - domain.controllers の DC を新規フォレストに昇格 (AD DS + DNS)
    - domain_join 指定のメンバを静的IP/DNS設定の上ドメイン参加

  冪等: 既にフォレストがあれば昇格をスキップ、既に参加済みなら参加をスキップ。

.NOTES
  ゲスト管理者は golden 既定 (Administrator / P@ssw0rd-Lab-Change!)。
  昇格後の DC / ドメインは同パスワードの $netbios\Administrator でアクセス。
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
function Log($m){ Write-Host "  [ad] $m" -ForegroundColor DarkCyan }
if (-not $ModelPath) { $ModelPath = Join-Path $RepoRoot "build\resolved.json" }
$cfg = Get-Content $ModelPath -Raw | ConvertFrom-Json
if (-not $L1Name) { $L1Name = $cfg.l1.name }

$domain = $cfg.domain
if (-not $domain) { throw "resolved model に domain がありません。AD 例 (l2/ad-forest.yml) で resolve してください。" }
$prefix = [int]($cfg.l1.nat.subnet -split '/')[1]
$dcs     = @($cfg.vms | Where-Object { $_.provision.forest })
$members = @($cfg.vms | Where-Object { $_.domain_join -and -not $_.provision.forest })
Log "fqdn=$($domain.fqdn) netbios=$($domain.netbios) DC=$($dcs.name -join ',') members=$($members.name -join ',')"
if (-not $dcs) { throw "DC がありません。" }

# DC は controllers[].ip を持つ。resolved の DC nic に IP が入っている。
$dc = $dcs[0]
$dcIp = $dc.nics[0].ip
$dcGw = $dc.nics[0].gw

# --- L1 への永続セッション ---
$l1cred = New-Object System.Management.Automation.PSCredential($L1User,(ConvertTo-SecureString $L1Password -AsPlainText -Force))
Log "L1 ($L1Name) への PowerShell Direct セッションを確立"
$l1 = New-PSSession -VMName $L1Name -Credential $l1cred

try {
    # L1 上で全工程を実行 (ゲストへの二段 PS Direct + 再起動待ちは L1 ローカルで完結)
    $result = Invoke-Command -Session $l1 -ScriptBlock {
        param($dcName,$dcIp,$dcGw,$prefix,$fqdn,$netbios,$dsrm,$guestPw,$memberJson)
        $ErrorActionPreference = 'Stop'
        $log = New-Object System.Collections.ArrayList
        function W($m){ [void]$log.Add($m) }

        $localCred  = New-Object System.Management.Automation.PSCredential('Administrator',(ConvertTo-SecureString $guestPw -AsPlainText -Force))
        $domCred    = New-Object System.Management.Automation.PSCredential("$netbios\Administrator",(ConvertTo-SecureString $guestPw -AsPlainText -Force))

        function Connect-Guest { param($vm,$cred,$timeoutSec=420)
            $dl=(Get-Date).AddSeconds($timeoutSec)
            while((Get-Date) -lt $dl){
                try { $s=New-PSSession -VMName $vm -Credential $cred -ErrorAction Stop; return $s } catch { Start-Sleep 8 }
            }
            throw "guest $vm へ PS Direct 接続できませんでした (timeout)"
        }
        function In-Guest { param($vm,$cred,[scriptblock]$sb,$args,$timeoutSec=420)
            $s=Connect-Guest $vm $cred $timeoutSec
            try { return Invoke-Command -Session $s -ScriptBlock $sb -ArgumentList $args } finally { Remove-PSSession $s }
        }

        # ===== DC =====
        # 既にフォレストがあるか (ドメイン admin で確認)
        $forestExists=$false
        try {
            $r = In-Guest $dcName $domCred { try { (Get-ADDomain).DNSRoot } catch { $null } } @() 60
            if ($r -eq $fqdn) { $forestExists=$true }
        } catch {}

        if ($forestExists) { W "DC $dcName: フォレスト $fqdn は既に存在 -> スキップ" }
        else {
            W "DC $dcName: 静的IP($dcIp/$prefix) + 改名"
            In-Guest $dcName $localCred {
                param($ip,$gw,$pfx,$name)
                $a = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
                Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -EA SilentlyContinue | Remove-NetIPAddress -Confirm:$false -EA SilentlyContinue
                Remove-NetRoute -InterfaceIndex $a.ifIndex -Confirm:$false -EA SilentlyContinue
                New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip -PrefixLength $pfx -DefaultGateway $gw | Out-Null
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses '127.0.0.1'
                if ($env:COMPUTERNAME -ne $name) { Rename-Computer -NewName $name -Force }
            } @($dcIp,$dcGw,$prefix,$dcName) 180

            W "DC $dcName: 再起動して改名を適用"
            In-Guest $dcName $localCred { Restart-Computer -Force } @() 120
            Start-Sleep 20

            W "DC $dcName: AD DS + DNS 役割を導入しフォレスト $fqdn を作成 (昇格)"
            In-Guest $dcName $localCred {
                param($fqdn,$nb,$dsrm)
                Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools | Out-Null
                Import-Module ADDSDeployment
                $sp = ConvertTo-SecureString $dsrm -AsPlainText -Force
                Install-ADDSForest -DomainName $fqdn -DomainNetbiosName $nb -SafeModeAdministratorPassword $sp `
                    -InstallDns -Force -NoRebootOnCompletion -SkipPreChecks | Out-Null
            } @($fqdn,$netbios,$dsrm) 900
            W "DC $dcName: 昇格完了。再起動"
            In-Guest $dcName $localCred { Restart-Computer -Force } @() 120 -ErrorAction SilentlyContinue
            Start-Sleep 30

            W "DC $dcName: AD サービス起動を待機"
            $dl=(Get-Date).AddSeconds(600); $up=$false
            while((Get-Date) -lt $dl){
                try {
                    $r = In-Guest $dcName $domCred { try { (Get-ADDomain).DNSRoot } catch { $null } } @() 60
                    if ($r -eq $fqdn) { $up=$true; break }
                } catch {}
                Start-Sleep 15
            }
            if (-not $up) { throw "DC $dcName のフォレストが時間内に起動しませんでした" }
            W "DC $dcName: フォレスト $fqdn 稼働確認 OK"
        }

        # ===== メンバ =====
        $members = $memberJson | ConvertFrom-Json
        foreach($m in $members){
            $mn=$m.name; $mip=$m.ip
            # 参加済みか (ローカルから WMI)
            $joined=$false
            try {
                $d = In-Guest $mn $localCred { (Get-CimInstance Win32_ComputerSystem).Domain } @() 60
                if ($d -eq $fqdn) { $joined=$true }
            } catch {}
            if ($joined) { W "member $mn: 既に $fqdn 参加済み -> スキップ"; continue }

            W "member $mn: 静的IP($mip/$prefix) + DNS($dcIp) + 改名"
            In-Guest $mn $localCred {
                param($ip,$gw,$pfx,$dns,$name)
                $a = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
                Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -EA SilentlyContinue | Remove-NetIPAddress -Confirm:$false -EA SilentlyContinue
                Remove-NetRoute -InterfaceIndex $a.ifIndex -Confirm:$false -EA SilentlyContinue
                New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip -PrefixLength $pfx -DefaultGateway $gw | Out-Null
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $dns
                if ($env:COMPUTERNAME -ne $name) { Rename-Computer -NewName $name -Force }
            } @($mip,$dcGw,$prefix,$dcIp,$mn) 180

            In-Guest $mn $localCred { Restart-Computer -Force } @() 120
            Start-Sleep 20

            W "member $mn: DC への到達を待機"
            In-Guest $mn $localCred {
                param($dcIp)
                $dl=(Get-Date).AddSeconds(300)
                while((Get-Date) -lt $dl){ if(Test-Connection $dcIp -Count 1 -Quiet){break}; Start-Sleep 5 }
            } @($dcIp) 360

            W "member $mn: ドメイン $fqdn へ参加"
            In-Guest $mn $localCred {
                param($fqdn,$nb,$pw)
                $dc = New-Object System.Management.Automation.PSCredential("$nb\Administrator",(ConvertTo-SecureString $pw -AsPlainText -Force))
                Add-Computer -DomainName $fqdn -Credential $dc -Force
            } @($fqdn,$netbios,$guestPw) 240
            In-Guest $mn $localCred { Restart-Computer -Force } @() 120
            Start-Sleep 25

            W "member $mn: 参加結果を確認"
            $dl=(Get-Date).AddSeconds(420); $ok=$false
            while((Get-Date) -lt $dl){
                try {
                    $d = In-Guest $mn $localCred { (Get-CimInstance Win32_ComputerSystem).Domain } @() 60
                    if ($d -eq $fqdn) { $ok=$true; break }
                } catch {}
                Start-Sleep 12
            }
            if ($ok) { W "member $mn: $fqdn 参加 確認 OK" } else { throw "member $mn の参加確認に失敗" }
        }

        return $log
    } -ArgumentList $dc.name,$dcIp,$dcGw,$prefix,$domain.fqdn,$domain.netbios,$domain.dsrm_password,$GuestPassword,($members | Select-Object name,@{n='ip';e={$_.nics[0].ip}} | ConvertTo-Json -Compress -Depth 5)

    $result | ForEach-Object { Log $_ }
}
finally {
    if ($l1) { Remove-PSSession $l1 }
}
Log "AD フォレスト構築 完了"
exit 0
