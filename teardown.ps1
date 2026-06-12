#Requires -Version 5.1
<#
.SYNOPSIS
  構築した検証環境を一発で削除する (bootstrap.ps1 の対になるエントリ)。

.DESCRIPTION
  既定で「L1 VM」と「中の L2 すべて」、および「制御 VM」を削除する。
  L2 は L1 のラボストア(VHDX)内に入れ子で存在するため、L1 VM とその全 attach
  ディスク (OS + labstore) を消せば L2 もまとめて消える (個別操作は不要)。

  既定で残すもの (再構築を速くするため):
    - CtrlNAT 仮想スイッチ / NetNat      … -IncludeSwitch で削除
    - build/ の成果物 (SSH 鍵 / resolved.json / host-cred.json) … -IncludeBuild で削除

  破壊的操作なので、-Force を付けない限り 'yes' の入力を求める。

.PARAMETER KeepControlNode  制御 VM (nested-lab-ctrl) を残す。
.PARAMETER IncludeSwitch    CtrlNAT スイッチと NetNat も削除する (完全クリーン)。
.PARAMETER IncludeBuild     build/ の成果物 (鍵・resolved.json 等) も削除する。
.PARAMETER Force            確認プロンプトを出さずに削除する。

.EXAMPLE
  .\teardown.ps1                       # 確認の上 L1(+L2) と制御 VM を削除
.EXAMPLE
  .\teardown.ps1 -KeepControlNode -Force
.EXAMPLE
  .\teardown.ps1 -IncludeSwitch -IncludeBuild -Force   # スイッチ/成果物まで完全削除
#>
[CmdletBinding()]
param(
    [string]$ModelPath,
    [string]$ControlNodeName = "nested-lab-ctrl",
    [switch]$KeepControlNode,
    [switch]$IncludeSwitch,
    [switch]$IncludeBuild,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
. (Join-Path $RepoRoot "scripts\HyperVLab.psm1.ps1")
function Log($m){ Write-Host "  [teardown] $m" -ForegroundColor DarkCyan }

if (-not $ModelPath) { $ModelPath = Join-Path $RepoRoot "build\resolved.json" }

# resolved.json から L1 名 / スイッチ名 / L2 名を取得 (無ければ既定にフォールバック)
$l1Name = $null; $switchName = "CtrlNAT"; $l2Names = @()
if (Test-Path $ModelPath) {
    $m = Get-Content $ModelPath -Raw | ConvertFrom-Json
    $l1Name = $m.l1.name
    if ($m.l1.nat.switch) { $switchName = $m.l1.nat.switch }
    $l2Names = @($m.vms | ForEach-Object { $_.name })
} else {
    Log "resolved.json が見つかりません ($ModelPath)。L1 名は -ModelPath で渡すか、build を残してください。"
}

# 削除対象の VM を確定 (存在するものだけ)
$vmTargets = @()
if ($l1Name) { $vmTargets += $l1Name }
if (-not $KeepControlNode) { $vmTargets += $ControlNodeName }
$vmTargets = @($vmTargets | Where-Object { Get-VM -Name $_ -ErrorAction SilentlyContinue })

# --- 削除対象の提示 ---
Write-Host ""
Write-Host "=============== 削除対象 ===============" -ForegroundColor Magenta
if ($l1Name) {
    $l2disp = if ($l2Names) { $l2Names -join ', ' } else { 'なし' }
    Write-Host ("  L1 VM        : {0}  (ディスクごと削除 → 中の L2 も消滅: {1})" -f $l1Name, $l2disp)
} else {
    Write-Host "  L1 VM        : (モデル不明 — resolved.json なし)" -ForegroundColor Yellow
}
if (-not $KeepControlNode) { Write-Host ("  制御 VM      : {0}" -f $ControlNodeName) }
if ($IncludeSwitch)        { Write-Host ("  NAT スイッチ : {0} (+ {0}-NAT)" -f $switchName) }
if ($IncludeBuild)         { Write-Host ("  成果物       : {0}\build (鍵 / resolved.json / host-cred.json)" -f $RepoRoot) }
if (-not $vmTargets -and -not $IncludeSwitch -and -not $IncludeBuild) {
    Write-Host "  (削除対象が見つかりませんでした。既に削除済みかもしれません)" -ForegroundColor Yellow
}
if (-not $IncludeSwitch) { Write-Host "  ※ CtrlNAT スイッチは残します (-IncludeSwitch で削除)" -ForegroundColor DarkGray }
if (-not $IncludeBuild)  { Write-Host "  ※ build/ の成果物は残します (-IncludeBuild で削除)" -ForegroundColor DarkGray }
Write-Host "========================================" -ForegroundColor Magenta

if (-not $vmTargets -and -not $IncludeSwitch -and -not $IncludeBuild) { exit 0 }

# --- 確認 ---
if (-not $Force) {
    $ans = Read-Host "本当に削除しますか? 続行するには 'yes' と入力"
    if ($ans -ne 'yes') { Log "中止しました (何も削除していません)"; exit 0 }
}

# --- VM 削除 (VM + 全 attach ディスク + 残骸フォルダ) ---
$dataRoot = if (Get-Command Get-LabDataRoot -ErrorAction SilentlyContinue) { Get-LabDataRoot -RepoRoot $RepoRoot } else { Join-Path $RepoRoot "data" }
foreach ($name in $vmTargets) {
    Log "削除中: $name (停止 → VM 削除 → ディスク削除)"
    [void](Remove-LabVm -Name $name)
    $vmDir = Join-Path (Join-Path $dataRoot "vms") $name
    if (Test-Path $vmDir) { Remove-Item $vmDir -Recurse -Force -ErrorAction SilentlyContinue }
    Log "削除完了: $name"
}

# --- NAT スイッチ (任意) ---
if ($IncludeSwitch) {
    [void](Remove-NatNetwork -SwitchName $switchName)
    Log "NAT スイッチ削除: $switchName (+ $switchName-NAT)"
}

# --- build 成果物 (任意) ---
if ($IncludeBuild) {
    $buildDir = Join-Path $RepoRoot "build"
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue; Log "build/ を削除" }
}

Write-Host ""
Log "環境削除 完了。再構築は bootstrap.ps1 を実行してください。"
exit 0
