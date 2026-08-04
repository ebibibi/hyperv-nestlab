#Requires -Version 5.1
<#
.SYNOPSIS
  Linux (Ubuntu cloud image) のベース VHDX を、宣言された最大 disk_gb まで拡張する。

.DESCRIPTION
  cloud image の仮想サイズは約 3.5GB しかない。L2 Linux は L1 上で**差分(ディファレンシング)
  ディスク**として作られるが、**差分ディスクの容量は親から決まる**ため、宣言の `disk_gb` を
  書いても子側では効かない (差分ディスク単体は Resize-VHD できない)。

  したがって、子を作る前に**親 (ベース VHDX) を宣言サイズへ拡張**する必要がある。拡張は
  動的 VHDX のメタデータ変更なので一瞬で終わり、ファイル実体はほとんど増えない。
  ゲスト側のパーティション/ファイルシステムは cloud-init の growpart が起動時に広げる。

  冪等: 既に目標以上なら何もしない。VM に接続中の VHDX は拡張できないため、
  ここでは L0 の assets/ にある配送元だけを対象にする (L1 側は再配送で追随する)。

.PARAMETER ModelPath
  確定モデル (build/resolved.json)。Linux VM の disk_gb の最大値を読む。

.PARAMETER ImagePath
  拡張するベース VHDX。既定は assets/ubuntu2404-cloudimg.vhdx。

.EXAMPLE
  scripts\Expand-LinuxBaseImage.ps1 -ModelPath build\resolved.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModelPath,
    [string]$ImagePath
)
$ErrorActionPreference = "Stop"
function Log($m) { Write-Host "  [baseimg] $m" -ForegroundColor DarkCyan }

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ImagePath) { $ImagePath = Join-Path $repoRoot "assets\ubuntu2404-cloudimg.vhdx" }
if (-not (Test-Path $ImagePath)) { Log "ベースイメージがまだありません (スキップ): $ImagePath"; exit 0 }

$model = Get-Content $ModelPath -Raw | ConvertFrom-Json
$linux = @($model.vms | Where-Object { $_.os -match 'ubuntu|debian|linux|rocky|alma' })
if (-not $linux) { Log "Linux L2 はありません (スキップ)"; exit 0 }

# 宣言された最大 disk_gb (os ディスク) を目標にする。
$targetGb = 0
foreach ($vm in $linux) {
    $os = @($vm.disks | Where-Object { $_.role -eq 'os' })[0]
    if ($os -and $os.size_gb -gt $targetGb) { $targetGb = [int]$os.size_gb }
}
if ($targetGb -le 0) { Log "宣言に os ディスクサイズがありません (スキップ)"; exit 0 }

$vhd = Get-VHD -Path $ImagePath
$currentGb = [math]::Round($vhd.Size / 1GB, 1)
if ($vhd.Size -ge ([int64]$targetGb * 1GB)) {
    Log ("ベースイメージは既に {0}GB (目標 {1}GB) -> スキップ" -f $currentGb, $targetGb)
    exit 0
}

Log ("ベースイメージを拡張: {0}GB -> {1}GB ({2})" -f $currentGb, $targetGb, (Split-Path $ImagePath -Leaf))
Resize-VHD -Path $ImagePath -SizeBytes ([int64]$targetGb * 1GB)
$after = [math]::Round((Get-VHD -Path $ImagePath).Size / 1GB, 1)
if ($after -lt $targetGb) { throw "拡張後のサイズが目標に達していません ($after GB < $targetGb GB)" }
Log ("拡張完了: {0}GB (ゲスト側は cloud-init の growpart が起動時に広げる)" -f $after)
exit 0
