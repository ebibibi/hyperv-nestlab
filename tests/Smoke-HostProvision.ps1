#Requires -Version 5.1
<#
  実機 Hyper-V に対する L0 プロビジョニングのスモークテスト。
    1. NAT ネットワーク + Nested 有効 L1 ホスト (空 VHDX) を作成
    2. 同じ操作を再実行し no-change を確認 (冪等性)
    3. 期待状態 (nested=On / 静的メモリ / MAC spoof / NAT 存在) を検証
    4. 後片付け (作成物を削除)
  結果は -ResultFile に JSON で書き出す (コンソール出力のゆらぎを避けるため)。
#>
[CmdletBinding()]
param(
    [string]$ResultFile = "$PSScriptRoot\..\build\smoke-result.json",
    [string]$Name   = "nestedlab-smoke",
    [string]$Switch = "SmokeNAT",
    [string]$Subnet = "10.99.0.0/24",
    [string]$HostIp = "10.99.0.1",
    [switch]$KeepArtifacts
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\scripts\HyperVLab.psm1.ps1")

$r = [ordered]@{ steps = [System.Collections.ArrayList]@(); ok = $false; error = $null }
function Add-Step($name, $value) { [void]$r.steps.Add([ordered]@{ step = $name; value = $value }) }

try {
    # 1st run (作成)
    $natChanged1 = Ensure-NatNetwork -SwitchName $Switch -Subnet $Subnet -HostIp $HostIp
    $vmChanged1  = Ensure-LabVm -Name $Name -Cpu 2 -MemoryGB 2 -Switch $Switch -DiskGB 8 -StaticMemory -Nested
    Add-Step "first_run_nat_changed" $natChanged1
    Add-Step "first_run_vm_changed"  $vmChanged1

    $vm = Get-VM -Name $Name
    $proc = Get-VMProcessor -VMName $Name
    $memObj = Get-VMMemory -VMName $Name
    $na = Get-VMNetworkAdapter -VMName $Name | Select-Object -First 1
    Add-Step "vm_exists" ($null -ne $vm)
    Add-Step "nested_on" ([bool]$proc.ExposeVirtualizationExtensions)
    Add-Step "static_memory" (-not $memObj.DynamicMemoryEnabled)
    Add-Step "mac_spoofing_on" ($na.MacAddressSpoofing -eq 'On')
    Add-Step "nat_exists" ([bool](Get-NetNat -Name "$Switch-NAT" -ErrorAction SilentlyContinue))
    $vmId1 = $vm.Id

    # 2nd run: an increased disk declaration must converge an existing VHDX.
    $natChanged2 = Ensure-NatNetwork -SwitchName $Switch -Subnet $Subnet -HostIp $HostIp
    $vmChanged2  = Ensure-LabVm -Name $Name -Cpu 2 -MemoryGB 2 -Switch $Switch -DiskGB 9 -StaticMemory -Nested
    Add-Step "second_run_nat_changed" $natChanged2
    Add-Step "second_run_vm_changed"  $vmChanged2
    $osDisk = (Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1).Path
    Add-Step "disk_expanded_to_9gb" ((Get-VHD -Path $osDisk).Size -eq 9GB)
    Add-Step "vm_id_stable" ((Get-VM -Name $Name).Id -eq $vmId1)
    Add-Step "vm_count_is_one" (@(Get-VM -Name $Name).Count -eq 1)

    # 3rd run: the converged declaration must be no-change.
    $natChanged3 = Ensure-NatNetwork -SwitchName $Switch -Subnet $Subnet -HostIp $HostIp
    $vmChanged3  = Ensure-LabVm -Name $Name -Cpu 2 -MemoryGB 2 -Switch $Switch -DiskGB 9 -StaticMemory -Nested
    Add-Step "third_run_nat_changed" $natChanged3
    Add-Step "third_run_vm_changed"  $vmChanged3
    $idempotent = (-not $natChanged3) -and (-not $vmChanged3)
    Add-Step "idempotent" $idempotent

    $r.ok = ($vmChanged1 -or $natChanged1) -and `
            $vmChanged2 -and `
            ((Get-VHD -Path $osDisk).Size -eq 9GB) -and `
            $idempotent -and `
            [bool]$proc.ExposeVirtualizationExtensions -and `
            (-not $memObj.DynamicMemoryEnabled) -and `
            ($na.MacAddressSpoofing -eq 'On')
}
catch {
    $r.error = $_.Exception.Message
}
finally {
    if (-not $KeepArtifacts) {
        try { Remove-LabVm -Name $Name | Out-Null } catch { Add-Step "cleanup_vm_error" $_.Exception.Message }
        try { Remove-NatNetwork -SwitchName $Switch | Out-Null } catch { Add-Step "cleanup_nat_error" $_.Exception.Message }
        Add-Step "cleaned_up" $true
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $ResultFile) | Out-Null
    $r | ConvertTo-Json -Depth 6 | Out-File -FilePath $ResultFile -Encoding utf8
}
