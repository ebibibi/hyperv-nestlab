#Requires -Version 5.1
<#
.SYNOPSIS
  Ubuntu cloud image (軽量版) を自動取得し、Hyper-V 用 VHDX に変換する。

.DESCRIPTION
  原則②(決定性): 固定 URL + SHA256 検証。原則①: qemu-img を自前で取得。
  冪等: 変換済み VHDX があれば何もしない。

  既定値は assets/images.yml の ubuntu2404-cloudimg と一致 (引数なしで動く)。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Url    = "https://cloud-images.ubuntu.com/releases/noble/release-20260518/ubuntu-24.04-server-cloudimg-amd64.img",
    [string]$Sha256 = "53fdde898feed8b027d94baa9cfe8229867f330a1d9c49dc7d84465ee7f229f7",
    [string]$ImgName  = "ubuntu-24.04-server-cloudimg-amd64.img",
    [string]$VhdxName = "ubuntu2404-cloudimg.vhdx"
)
$ErrorActionPreference = "Stop"
$assets = Join-Path $RepoRoot "assets"
$tools  = Join-Path $RepoRoot "tools"
$img    = Join-Path $assets $ImgName
$vhdx   = Join-Path $assets $VhdxName
New-Item -ItemType Directory -Force -Path $assets, $tools | Out-Null

function Log($m){ Write-Host "  [ubuntu] $m" -ForegroundColor DarkCyan }

if (Test-Path $vhdx) { Log "VHDX は既に存在します (no-change): $vhdx"; exit 0 }

# --- qemu-img を確保 ---
$qemu = $null
$cmd = Get-Command qemu-img -ErrorAction SilentlyContinue
if ($cmd) { $qemu = $cmd.Source }
elseif (Test-Path (Join-Path $tools "qemu-img.exe")) { $qemu = Join-Path $tools "qemu-img.exe" }
else {
    $dest = Join-Path $tools "qemu-img.exe"
    $primary  = "https://github.com/fdcastel/qemu-img-windows-x64/releases/latest/download/qemu-img.exe"
    $fallback = "https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip"
    try {
        Log "qemu-img を取得 (GitHub latest)"
        Invoke-WebRequest -Uri $primary -OutFile $dest -UseBasicParsing
        $qemu = $dest
    } catch {
        Log "GitHub 取得失敗。Cloudbase zip にフォールバック"
        $zip = Join-Path $tools "qemu-img.zip"
        Invoke-WebRequest -Uri $fallback -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath (Join-Path $tools "qemu") -Force
        $found = Get-ChildItem -Path (Join-Path $tools "qemu") -Recurse -Filter qemu-img.exe | Select-Object -First 1
        if (-not $found) { throw "qemu-img.exe を取得できませんでした。手動で $dest に配置してください。" }
        $qemu = $found.FullName
    }
}
Log "qemu-img: $qemu"

# --- cloud image をダウンロード + SHA256 検証 ---
if (-not (Test-Path $img)) {
    Log "ダウンロード中 (約599MB): $Url"
    try { Start-BitsTransfer -Source $Url -Destination $img -ErrorAction Stop }
    catch { Invoke-WebRequest -Uri $Url -OutFile $img -UseBasicParsing }
}
Log "SHA256 検証中..."
$actual = (Get-FileHash -Path $img -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $Sha256.ToLower()) {
    Remove-Item $img -Force
    throw "SHA256 不一致 (期待 $Sha256 / 実際 $actual)。images.yml のピンを更新してください。"
}
Log "SHA256 OK"

# --- qcow2 -> VHDX 変換 (動的) ---
Log "VHDX へ変換中..."
& $qemu convert -f qcow2 -O vhdx -o subformat=dynamic $img $vhdx
if ($LASTEXITCODE -ne 0) { throw "qemu-img 変換に失敗しました。" }
Log "完了: $vhdx"
exit 0
