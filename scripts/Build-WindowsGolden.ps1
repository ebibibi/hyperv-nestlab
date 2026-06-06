#Requires -Version 5.1
<#
.SYNOPSIS
  配置された Windows Server ISO から golden VHDX を無人ビルドする。

.DESCRIPTION
  原則①: 利用者の操作は「ISO を assets/iso/ に置く」だけ。
  本スクリプトが Packer を自前取得し、Autounattend (cd_content) による
  無人インストール -> sysprep -> エクスポートで golden VHDX を生成する。
  冪等: golden VHDX があれば何もしない。

  ISO が無い場合はダウンロード手順をガイドして中断する (規約同意が必要なため自動化しない)。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$IsoDir   = $null,
    [string]$VhdxName = "win2025-golden.vhdx",
    [string]$AdminPassword = "P@ssw0rd-Lab-Change!"
)
$ErrorActionPreference = "Stop"
$assets = Join-Path $RepoRoot "assets"
$tools  = Join-Path $RepoRoot "tools"
if (-not $IsoDir) { $IsoDir = Join-Path $assets "iso" }
$vhdx   = Join-Path $assets $VhdxName
New-Item -ItemType Directory -Force -Path $assets, $tools, $IsoDir | Out-Null

function Log($m){ Write-Host "  [win] $m" -ForegroundColor DarkCyan }

if (Test-Path $vhdx) { Log "golden VHDX は既に存在します (no-change): $vhdx"; exit 0 }

# --- ISO 配置の確認 (無ければガイドして中断) ---
$iso = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -match '(?i)SERVER_EVAL|server.*2025|2025.*server|_SERVER_' } |
       Select-Object -First 1
if (-not $iso) {
    $iso = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $iso) {
    # ISO はフォーム不要の直リンクから自動ダウンロード
    & (Join-Path $PSScriptRoot "Get-WindowsIso.ps1") -RepoRoot $RepoRoot -IsoDir $IsoDir
    if ($LASTEXITCODE -ne 0) { exit 3 }
    $iso = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '(?i)SERVER_EVAL|server.*2025|2025.*server|_SERVER_' } | Select-Object -First 1
    if (-not $iso) { $iso = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $iso) { exit 3 }
}
Log "ISO 検出: $($iso.Name)"

# --- Packer を確保 (版固定 zip) ---
$packer = Join-Path $tools "packer.exe"
if (-not (Test-Path $packer)) {
    $purl = "https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_windows_amd64.zip"
    Log "Packer を取得 (1.11.2)"
    $zip = Join-Path $tools "packer.zip"
    Invoke-WebRequest -Uri $purl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tools -Force
    Remove-Item $zip -Force
}
Log "Packer: $packer"

# --- Packer ビルド ---
$pkrDir = Join-Path $RepoRoot "packer\windows-server"
$outDir = Join-Path $tools "packer-out-win2025"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }  # Packer は出力先が空である必要
Push-Location $pkrDir
try {
    & $packer init .
    if ($LASTEXITCODE -ne 0) { throw "packer init に失敗しました。" }
    & $packer build `
        -var ("iso_path=" + $iso.FullName) `
        -var ("admin_password=" + $AdminPassword) `
        -var ("output_directory=" + $outDir) `
        .
    if ($LASTEXITCODE -ne 0) { throw "Packer ビルドに失敗しました。" }
} finally { Pop-Location }

# 生成された VHDX を golden として確定配置
$built = Get-ChildItem -Path $outDir -Recurse -Filter *.vhdx -ErrorAction SilentlyContinue |
         Sort-Object Length -Descending | Select-Object -First 1
if (-not $built) { throw "ビルドは終了しましたが VHDX が見つかりません: $outDir" }
Move-Item -Path $built.FullName -Destination $vhdx -Force
Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue
Log "完了: $vhdx"
exit 0
