#Requires -Version 5.1
<#
.SYNOPSIS
  既存ラボのドメインに、追加のドメインコントローラーを 1 台足す。

.DESCRIPTION
  `Initialize-AdForest.ps1` は l2/*.yml の domain.controllers のうち **先頭 1 台だけ** を
  新規フォレストに昇格する。複数 DC を宣言しても 2 台目以降は作られないため、
  「DC 間の複製」を扱う検証（複製の失敗、トゥームストーン超過、repadmin / dcdiag の
  複製系テストなど）ができなかった。本スクリプトはその穴を埋める。

  処理は L0 -> L1 -> L2 の二段 PowerShell Direct で行う（Initialize-AdForest.ps1 と同じ方式。
  L2 は L1 内 NAT に隔離されており、物理ネットワークからは届かないため）。

    1. golden VHDX を複製して新しい VM を作る
    2. 起動して PS Direct で入れるまで待つ
    3. 静的 IP と DNS（既存 DC を向ける）を設定する
    4. AD DS を導入し、既存ドメインへ **追加 DC** として昇格する
    5. 再起動を待ち、複製が動いていることを確認する

  冪等: 同名 VM が既にある場合は作成をスキップし、既に DC 昇格済みなら昇格をスキップする。

.PARAMETER Name
  追加する DC の名前（VM 名 / コンピューター名）。既定 dc02。

.PARAMETER IPAddress
  追加する DC に設定する静的 IP。既定 10.10.0.11。

.PARAMETER ExistingDcIp
  既存 DC の IP（DNS 参照先）。既定 10.10.0.10。

.PARAMETER DomainFqdn / -NetBIOS
  参加するドメイン。既定 corp.contoso.local / CORP。

.EXAMPLE
  .\Add-LabDomainController.ps1
  dc02 を 10.10.0.11 で追加する。

.EXAMPLE
  .\Add-LabDomainController.ps1 -Name dc03 -IPAddress 10.10.0.12
#>
[CmdletBinding()]
param(
    [string]$L1Name        = 'nested-lab-01',
    [string]$Name          = 'dc02',
    [string]$IPAddress     = '10.10.0.11',
    [int]$PrefixLength     = 24,
    [string]$Gateway       = '10.10.0.1',
    [string]$ExistingDcIp  = '10.10.0.10',
    [string]$DomainFqdn    = 'corp.contoso.local',
    [string]$NetBIOS       = 'CORP',
    [string]$GuestPassword = 'P@ssw0rd-Lab-Change!',
    [string]$DsrmPassword  = 'P@ssw0rd-DSRM-Lab!',
    [string]$SwitchName    = 'LabNAT',
    [int]$MemoryGB         = 4,
    [int]$MinMemoryGB      = 2,
    [int]$CpuCount         = 2,
    [string]$GoldenPath    = 'L:\images\win2025-golden-en-us.vhdx',
    [string]$VmRoot        = 'L:\vms'
)
$ErrorActionPreference = 'Stop'
function Log($m) { Write-Host "  [add-dc] $m" -ForegroundColor DarkCyan }

$l1Cred = New-Object System.Management.Automation.PSCredential(
    'Administrator', (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))

Log "L1=$L1Name へ接続します"
$l1 = New-PSSession -VMName $L1Name -Credential $l1Cred

try {
    $result = Invoke-Command -Session $l1 -ScriptBlock {
        param($Name,$IPAddress,$PrefixLength,$Gateway,$ExistingDcIp,$DomainFqdn,$NetBIOS,
              $GuestPassword,$DsrmPassword,$SwitchName,$MemoryGB,$MinMemoryGB,$CpuCount,$GoldenPath,$VmRoot)

        $ErrorActionPreference = 'Stop'
        $log = New-Object System.Collections.ArrayList
        function W($m) { [void]$log.Add("$([datetime]::Now.ToString('HH:mm:ss')) $m") }

        $localCred = New-Object System.Management.Automation.PSCredential(
            'Administrator', (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))
        $domCred = New-Object System.Management.Automation.PSCredential(
            "$NetBIOS\Administrator", (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))

        function Connect-Guest {
            param($vm, $cred, $timeoutSec = 1200)
            $dl = (Get-Date).AddSeconds($timeoutSec)
            while ((Get-Date) -lt $dl) {
                try { return New-PSSession -VMName $vm -Credential $cred -ErrorAction Stop }
                catch { Start-Sleep 10 }
            }
            throw "guest $vm へ PS Direct 接続できませんでした (timeout ${timeoutSec}s)"
        }

        # ===== 1. VM 作成 =====
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if (-not $vm) {
            $dir  = Join-Path $VmRoot $Name
            $vhd  = Join-Path $dir "$Name-os.vhdx"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            W "golden を複製しています: $GoldenPath -> $vhd"
            Copy-Item -LiteralPath $GoldenPath -Destination $vhd -Force

            W "VM を作成しています ($Name)"
            $vm = New-VM -Name $Name -MemoryStartupBytes ($MemoryGB * 1GB) -Generation 2 `
                         -VHDPath $vhd -SwitchName $SwitchName
            Set-VM -Name $Name -ProcessorCount $CpuCount -AutomaticCheckpointsEnabled $false
            # 既存 VM が固定メモリで L1 を埋めていることが多いため、追加 DC は動的メモリにする。
            # （固定で確保しようとすると 0x8007000E「メモリリソース不足」で起動できない）
            Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
                         -MinimumBytes ($MinMemoryGB * 1GB) `
                         -StartupBytes ($MinMemoryGB * 1GB) `
                         -MaximumBytes ($MemoryGB * 1GB)
            # 入れ子仮想化は不要。DC なので既定のままでよい。
            Start-VM -Name $Name
            W "VM を起動しました。OOBE 完了を待ちます（数分かかります）"
        } else {
            W "VM $Name は既に存在します（作成をスキップ）"
            if ($vm.State -ne 'Running') {
                # 起動前にメモリ設定を見直す（固定のままだと L1 の空きが足りず起動できない）
                if (-not $vm.DynamicMemoryEnabled) {
                    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
                                 -MinimumBytes ($MinMemoryGB * 1GB) `
                                 -StartupBytes ($MinMemoryGB * 1GB) `
                                 -MaximumBytes ($MemoryGB * 1GB)
                    W "メモリを動的（$MinMemoryGB〜$MemoryGB GB）に変更しました"
                }
                Start-VM -Name $Name
                W 'VM を起動しました'
            }
        }

        # ===== 2. 昇格済みかどうかを先に判定 =====
        $alreadyDc = $false
        try {
            $s = New-PSSession -VMName $Name -Credential $domCred -ErrorAction Stop
            $alreadyDc = Invoke-Command -Session $s -ScriptBlock {
                (Get-CimInstance Win32_ComputerSystem).DomainRole -in 4, 5
            }
            Remove-PSSession $s
        } catch { }

        if ($alreadyDc) {
            W "$Name は既にドメインコントローラーです（昇格をスキップ）"
            return $log.ToArray()
        }

        # ===== 3. ネットワーク設定 =====
        W 'ゲストへ接続しています（ローカル管理者）'
        $s = Connect-Guest $Name $localCred 1800
        try {
            $netLog = Invoke-Command -Session $s -ScriptBlock {
                param($n, $ip, $pfx, $gw, $dns)
                $out = @()
                $if = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
                if (-not $if) { $if = Get-NetAdapter | Select-Object -First 1 }

                $cur = Get-NetIPAddress -InterfaceIndex $if.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.IPAddress -eq $ip }
                if (-not $cur) {
                    Get-NetIPAddress -InterfaceIndex $if.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                    Get-NetRoute -InterfaceIndex $if.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetIPAddress -InterfaceIndex $if.ifIndex -IPAddress $ip -PrefixLength $pfx -DefaultGateway $gw | Out-Null
                    $out += "IP を設定: $ip/$pfx gw=$gw"
                } else {
                    $out += "IP は設定済み: $ip"
                }
                Set-DnsClientServerAddress -InterfaceIndex $if.ifIndex -ServerAddresses $dns
                $out += "DNS を設定: $dns"

                if ($env:COMPUTERNAME -ne $n) {
                    Rename-Computer -NewName $n -Force
                    $out += "コンピューター名を $n に変更（再起動が必要）"
                }
                $out
            } -ArgumentList $Name, $IPAddress, $PrefixLength, $Gateway, $ExistingDcIp
            $netLog | ForEach-Object { W $_ }
        } finally { Remove-PSSession $s }

        # 名前変更を反映するため再起動
        W '再起動しています（コンピューター名の反映）'
        Restart-VM -Name $Name -Force -Wait -For Heartbeat
        Start-Sleep -Seconds 20

        # ===== 4. AD DS 導入と追加 DC 昇格 =====
        W 'AD DS を導入し、追加 DC として昇格します（数分かかります）'
        $s = Connect-Guest $Name $localCred 1800
        try {
            $promoLog = Invoke-Command -Session $s -ScriptBlock {
                param($fqdn, $netbios, $pw, $dsrm)
                $out = @()
                $f = Get-WindowsFeature AD-Domain-Services
                if (-not $f.Installed) {
                    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
                    $out += 'AD DS 役割を導入しました'
                } else {
                    $out += 'AD DS 役割は導入済み'
                }
                Import-Module ADDSDeployment
                $cred = New-Object System.Management.Automation.PSCredential(
                    "$netbios\Administrator", (ConvertTo-SecureString $pw -AsPlainText -Force))
                Install-ADDSDomainController `
                    -DomainName $fqdn `
                    -Credential $cred `
                    -SafeModeAdministratorPassword (ConvertTo-SecureString $dsrm -AsPlainText -Force) `
                    -InstallDns:$true `
                    -NoGlobalCatalog:$false `
                    -NoRebootOnCompletion:$true `
                    -Force `
                    -Confirm:$false | Out-Null
                $out += '昇格コマンドが完了しました（再起動待ち）'
                $out
            } -ArgumentList $DomainFqdn, $NetBIOS, $GuestPassword, $DsrmPassword
            $promoLog | ForEach-Object { W $_ }
        } finally { Remove-PSSession $s }

        W '再起動しています（昇格の反映）'
        Restart-VM -Name $Name -Force -Wait -For Heartbeat
        Start-Sleep -Seconds 30

        # ===== 5. 確認 =====
        W '昇格結果を確認しています'
        $s = Connect-Guest $Name $domCred 1800
        try {
            $verify = Invoke-Command -Session $s -ScriptBlock {
                $out = @()
                $out += 'DomainRole=' + (Get-CimInstance Win32_ComputerSystem).DomainRole
                try {
                    Import-Module ActiveDirectory
                    $out += 'DC 一覧: ' + ((Get-ADDomainController -Filter * | ForEach-Object { $_.Name }) -join ', ')
                    $out += '複製相手: ' + (@(Get-ADReplicationPartnerMetadata -Target $env:COMPUTERNAME -ErrorAction SilentlyContinue).Count)
                } catch { $out += 'AD 確認でエラー: ' + $_.Exception.Message }
                $out
            }
            $verify | ForEach-Object { W $_ }
        } finally { Remove-PSSession $s }

        return $log.ToArray()
    } -ArgumentList $Name,$IPAddress,$PrefixLength,$Gateway,$ExistingDcIp,$DomainFqdn,$NetBIOS,
                    $GuestPassword,$DsrmPassword,$SwitchName,$MemoryGB,$MinMemoryGB,$CpuCount,$GoldenPath,$VmRoot

    $result | ForEach-Object { Log $_ }
    Log '完了しました'
}
finally {
    Remove-PSSession $l1 -ErrorAction SilentlyContinue
}
