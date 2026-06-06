#Requires -Version 5.1
<#
.SYNOPSIS
  L0 (物理 Hyper-V ホスト) 上で L1 Nested ホスト VM を冪等に作成する。

.DESCRIPTION
  確定モデル (build/resolved.json) を入力に、HyperVLab の冪等関数で
    - L1 を接続する L0 スイッチの存在確認 (既定 "Default Switch")
    - L1 ホスト VM の作成 + Nested 有効化 + 静的メモリ + MAC spoof
  を行う。L1 の内側 (LabNAT / Hyper-V 役割 / L2 VM) は Ansible が担当する。

  base_image (golden VHDX) が images カタログにあればそれを複製し、
  無ければ空の動的 VHDX を作成する (OS 導入は Phase 2/イメージ整備で確定)。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Model,
    [switch]$Start
)
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\HyperVLab.psm1.ps1")

$m = Get-Content $Model -Raw | ConvertFrom-Json
$l1 = $m.l1
$l0switch = if ($l1.l0_switch) { $l1.l0_switch } else { "Default Switch" }

# L0 スイッチの存在確認 (無ければ NAT スイッチを用意)
if (-not (Get-VMSwitch -Name $l0switch -ErrorAction SilentlyContinue)) {
    Write-Host "  !! L0 スイッチ '$l0switch' が見つかりません。L0 用 NAT スイッチ HostNAT を作成します。" -ForegroundColor Yellow
    Ensure-NatNetwork -SwitchName "HostNAT" -Subnet "10.30.0.0/24" -HostIp "10.30.0.1" | Out-Null
    $l0switch = "HostNAT"
}

# base_image 解決。L1(ホスト)は英語固定 golden (resolver が base_image_file=win2025-golden-en-us.vhdx を付与)。
$base = $null
$baseFile = if ($l1.base_image_file) { $l1.base_image_file } elseif ($l1.base_image) { "$($l1.base_image).vhdx" } else { $null }
if ($baseFile) {
    $candidate = Join-Path $RepoRoot ("assets\{0}" -f $baseFile)
    if (Test-Path $candidate) { $base = $candidate }
}
if (-not $base) {
    Write-Host "  !! golden イメージ未整備のため空 VHDX で L1 を作成します (OS 導入は Phase 2)。" -ForegroundColor Yellow
}

# 自己完結構造: VM ディスクはリポジトリ配下 data/ に置く
$dataRoot = Get-LabDataRoot -RepoRoot $RepoRoot
$changed = Ensure-LabVm -Name $l1.name -Cpu ([int]$l1.cpu) -MemoryGB ([int]$l1.memory_gb) `
                        -Switch $l0switch -BaseImage $base -DiskGB ([int]$l1.disk_gb) `
                        -Generation 2 -DataRoot $dataRoot -StaticMemory -Nested:([bool]$l1.nested)

if ($changed) { Write-Host "  ->  L1 '$($l1.name)' を作成/収束しました (switch=$l0switch, nested=$($l1.nested))" -ForegroundColor Green }
else          { Write-Host "  ->  L1 '$($l1.name)' は既に期待状態です (no-change)" -ForegroundColor DarkGray }

if ($Start -and $base) {
    if ((Get-VM -Name $l1.name).State -ne 'Running') { Start-VM -Name $l1.name }
}
exit 0
