#Requires -Version 5.1
<#
  HyperVLab - Hyper-V 操作の冪等ヘルパー関数群。

  すべて「Get -> 無ければ作成 / あれば期待状態へ収束」型。各関数は
  [bool] $changed (何か変更したか) を返すので、呼び出し側で no-change 判定できる。

  レイヤ分担 (plan.md の refinement):
    - L0 レベル (NAT / L1 ホスト / 制御 VM) ... ホスト上の PowerShell が担当 (本モジュール)
    - L1 内側 (Hyper-V 役割 / L2 VM / AD / クラスタ) ... Ansible が担当
#>

function Ensure-NatNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SwitchName,
        [Parameter(Mandatory)][string]$Subnet,    # e.g. 10.20.0.0/24
        [Parameter(Mandatory)][string]$HostIp
    )
    $changed = $false
    $prefix = [int]($Subnet.Split('/')[1])

    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        $changed = $true
    }

    $ifAlias = "vEthernet ($SwitchName)"
    $hasIp = Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -eq $HostIp }
    if (-not $hasIp) {
        New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $HostIp -PrefixLength $prefix -ErrorAction SilentlyContinue | Out-Null
        $changed = $true
    }

    $natName = "$SwitchName-NAT"
    if (-not (Get-NetNat -Name $natName -ErrorAction SilentlyContinue)) {
        New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $Subnet | Out-Null
        $changed = $true
    }
    return $changed
}

function Get-LabDataRoot {
    <#
      大容量データ (VM ディスク等) の格納ルートを解決する。
      原則: 「OSS の実体を置いたフォルダ以下に全部入る」自己完結構造。
      優先順位:
        1) 明示引数 / 環境変数 NESTEDLAB_DATA_ROOT
        2) リポジトリ配下の data/ (RepoRoot 既知のとき)
        3) 最後の手段として Hyper-V 既定 (C:\ProgramData) ※非推奨
    #>
    [CmdletBinding()]
    param([string]$RepoRoot, [string]$DataRoot)
    if ($DataRoot) { $root = $DataRoot }
    elseif ($env:NESTEDLAB_DATA_ROOT) { $root = $env:NESTEDLAB_DATA_ROOT }
    elseif ($RepoRoot) { $root = Join-Path $RepoRoot "data" }
    else { $root = (Get-VMHost).VirtualHardDiskPath }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return $root
}

function Ensure-LabVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Cpu,
        [Parameter(Mandatory)][int]$MemoryGB,
        [Parameter(Mandatory)][string]$Switch,
        [string]$BaseImage,                 # 省略時は空の動的 VHDX を作成
        [int]$DiskGB = 120,
        [int]$Generation = 2,
        [string]$DataRoot,                  # VM ディスク格納ルート (自己完結構造)
        [switch]$StaticMemory,
        [switch]$Nested
    )
    $changed = $false
    $mem = [int64]$MemoryGB * 1GB
    $desiredDiskBytes = [int64]$DiskGB * 1GB

    if (-not (Get-VM -Name $Name -ErrorAction SilentlyContinue)) {
        $vmRoot = if ($DataRoot) { $DataRoot } elseif ($env:NESTEDLAB_DATA_ROOT) { $env:NESTEDLAB_DATA_ROOT } else { (Get-VMHost).VirtualHardDiskPath }
        $diskDir = Join-Path (Join-Path $vmRoot "vms") $Name
        New-Item -ItemType Directory -Force -Path $diskDir | Out-Null
        $osDisk = Join-Path $diskDir "$Name-os.vhdx"
        if (-not (Test-Path $osDisk)) {
            if ($BaseImage -and (Test-Path $BaseImage)) {
                Copy-Item -Path $BaseImage -Destination $osDisk
            } else {
                New-VHD -Path $osDisk -SizeBytes $desiredDiskBytes -Dynamic | Out-Null
            }
        }
        New-VM -Name $Name -MemoryStartupBytes $mem -Generation $Generation `
               -VHDPath $osDisk -SwitchName $Switch | Out-Null
        # Gen2: ブート順をディスク優先にする。空の File エントリが先頭に来ると
        # 黒画面で停止することがあるため、明示的にディスク→NIC の順に設定する。
        if ($Generation -eq 2) {
            $hd = Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1
            $na = Get-VMNetworkAdapter -VMName $Name | Select-Object -First 1
            $order = @($hd); if ($na) { $order += $na }
            Set-VMFirmware -VMName $Name -BootOrder $order
            # Windows golden は MicrosoftWindows テンプレートで Secure Boot 可
            Set-VMFirmware -VMName $Name -SecureBootTemplate MicrosoftWindows
        }
        $changed = $true
    }

    # A cloned golden keeps the source VHDX maximum size (currently 40 GB). Reconcile both
    # newly cloned and already deployed OS disks with the declarative DiskGB value. Expansion
    # of a Gen2 SCSI VHDX is supported while running; never shrink a disk that is already larger.
    $osDrive = Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1
    if ($osDrive -and $osDrive.Path) {
        $vhd = Get-VHD -Path $osDrive.Path
        if ($vhd.Size -lt $desiredDiskBytes) {
            Resize-VHD -Path $osDrive.Path -SizeBytes $desiredDiskBytes
            $changed = $true
        }
    }

    # vCPU / 静的メモリ / Nested拡張(ExposeVirtualizationExtensions) は Hyper-V の仕様上
    # VM がオフでないと変更できない。既存VMで宣言値とドリフトがある時だけ一旦停止して適用する
    # （起動は呼び出し側=Invoke-HostProvision が State!=Running を見て行う）。これにより
    # 「展開済み L1 の cpu/memory_gb を書き換えて再実行 → その値へ収束」を冪等に実現する。
    $m0         = Get-VMMemory -VMName $Name
    $needCpu    = (Get-VMProcessor -VMName $Name).Count -ne $Cpu
    $needMem    = $StaticMemory -and ($m0.DynamicMemoryEnabled -or $m0.Startup -ne $mem)
    $needNested = $Nested -and (-not (Get-VMProcessor -VMName $Name).ExposeVirtualizationExtensions)
    if ($needCpu -or $needMem -or $needNested) {
        if ((Get-VM -Name $Name).State -eq 'Running') { Stop-VM -Name $Name -Force }  # -Force=確認なしのゲストシャットダウン
        if ($needCpu)    { Set-VMProcessor -VMName $Name -Count $Cpu }
        if ($needMem)    { Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes $mem }
        if ($needNested) { Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true }
        $changed = $true
    }

    if ($Nested) {
        # MAC spoofing は稼働中でも設定可。ドリフトのみ調整。
        foreach ($na in (Get-VMNetworkAdapter -VMName $Name)) {
            if ($na.MacAddressSpoofing -ne 'On') {
                $na | Set-VMNetworkAdapter -MacAddressSpoofing On
                $changed = $true
            }
        }
    }
    return $changed
}

function Remove-LabVm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { return $false }
    if ($vm.State -ne 'Off') { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue }
    $disks = (Get-VMHardDiskDrive -VMName $Name).Path
    Remove-VM -Name $Name -Force
    foreach ($d in $disks) { if ($d -and (Test-Path $d)) { Remove-Item $d -Force -ErrorAction SilentlyContinue } }
    return $true
}

function Remove-NatNetwork {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SwitchName)
    $changed = $false
    $natName = "$SwitchName-NAT"
    if (Get-NetNat -Name $natName -ErrorAction SilentlyContinue) { Remove-NetNat -Name $natName -Confirm:$false; $changed = $true }
    if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) { Remove-VMSwitch -Name $SwitchName -Force; $changed = $true }
    return $changed
}
