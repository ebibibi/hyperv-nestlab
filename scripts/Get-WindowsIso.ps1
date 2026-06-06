#Requires -Version 5.1
<#
.SYNOPSIS
  Windows Server 2025 評価版 ISO をフォーム登録なしの直リンクから自動ダウンロードする。

.DESCRIPTION
  以前は ISO の配置を利用者に案内して待機していたが、Microsoft の評価版は
  登録フォームなしの固定 fwlink から直接取得できるため、Ubuntu イメージと同様に
  完全自動ダウンロードに統一する (原則① 利用者の手間ゼロ / 原則③ 使い回し容易)。

  既定 URL は fwlink (linkid=2345828)。評価版のため SHA256 ピンは行わず
  (Microsoft が最新版を随時更新するため)、取得後に install.wim/esd の有無で妥当性検証する。
  別言語・別版にしたい場合は -Url で差し替え可能。

  冪等: IsoDir に有効な ISO があれば何もしない。

.PARAMETER Url
  ISO 直リンク。既定は英語(en-us)評価版。日本語版は
  https://go.microsoft.com/fwlink/?linkid=2345828&clcid=0x411&culture=ja-jp&country=JP
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$IsoDir,
    [string]$Url = "https://go.microsoft.com/fwlink/?linkid=2345828&clcid=0x409&culture=en-us&country=us",
    [string]$IsoName = "windows-server-2025-eval.iso"
)
$ErrorActionPreference = "Stop"
if (-not $IsoDir) { $IsoDir = Join-Path (Join-Path $RepoRoot "assets") "iso" }
New-Item -ItemType Directory -Force -Path $IsoDir | Out-Null
function Log($m){ Write-Host "  [win-iso] $m" -ForegroundColor DarkCyan }

# 冪等: 既に評価版 ISO があればスキップ
$existing = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)SERVER_EVAL|server.*2025|2025.*server|_SERVER_' -and $_.Length -gt 1GB } |
            Select-Object -First 1
if ($existing) { Log "ISO は既に配置済み (no-change): $($existing.Name)"; exit 0 }

$dest = Join-Path $IsoDir $IsoName
$tmp  = "$dest.downloading"
if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Log "Windows Server 2025 評価版 ISO を直接ダウンロード中 (約7-8GB / フォーム不要)..."
Log "  URL: $Url"
try {
    Start-BitsTransfer -Source $Url -Destination $tmp -ErrorAction Stop
} catch {
    Log "BITS 失敗。Invoke-WebRequest にフォールバック"
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
}

$len = (Get-Item $tmp).Length
if ($len -lt 1GB) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw "ダウンロードした ISO が小さすぎます ($([math]::Round($len/1MB,1))MB)。URL を確認してください。" }

# 先に最終名 (.iso) へ確定してから検証する。
# Mount-DiskImage は拡張子で仮想ディスクプロバイダを決めるため、.downloading のままだと
# 「仮想ディスク サポート プロバイダーが見つかりませんでした」で失敗する。
if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
Move-Item -Path $tmp -Destination $dest -Force

# 妥当性検証: マウントして install.wim/esd の存在を確認
Log "ISO をマウントして検証中..."
$ok = $false
try {
    $img = Mount-DiskImage -ImagePath $dest -PassThru
    $vol = ($img | Get-Volume).DriveLetter
    $ok = @("$vol`:\sources\install.wim","$vol`:\sources\install.esd") | Where-Object { Test-Path $_ } | Select-Object -First 1
} finally {
    Dismount-DiskImage -ImagePath $dest -ErrorAction SilentlyContinue | Out-Null
}
if (-not $ok) { Remove-Item $dest -Force -ErrorAction SilentlyContinue; throw "ダウンロードした ISO に install.wim/esd がありません。URL/取得結果を確認してください。" }

Log "完了: $dest ($([math]::Round((Get-Item $dest).Length/1GB,2))GB)"
exit 0
