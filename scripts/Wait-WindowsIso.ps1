#Requires -Version 5.1
<#
.SYNOPSIS
  Windows Server 2025 評価版 ISO の配置を利用者にガイドし、配置されるまで待機・検証する。

.DESCRIPTION
  原則① (前提は Hyper-V のみ) の唯一の例外が「Windows ISO の配置」。ライセンス同意が
  必要なため自動ダウンロードできない。本スクリプトは:
    1. ISO が既にあれば検証して即 OK
    2. 無ければ本番表示用のステップガイドを出す
    3. -NoWait なら exit 3 で中断 (利用者が配置後に再実行)
       既定はポーリングで配置を待ち、検出したら ISO の妥当性を検証する

.PARAMETER IsoDir   ISO 配置フォルダ (既定 assets\iso)
.PARAMETER NoWait   待機せず、ガイド表示後すぐ exit 3
.PARAMETER PollSeconds   ポーリング間隔 (既定 15)
.PARAMETER TimeoutMinutes 待機タイムアウト (既定 60)
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$IsoDir,
    [switch]$NoWait,
    [int]$PollSeconds = 15,
    [int]$TimeoutMinutes = 60
)
$ErrorActionPreference = "Stop"
if (-not $IsoDir) { $IsoDir = Join-Path $RepoRoot "assets\iso" }
New-Item -ItemType Directory -Force -Path $IsoDir | Out-Null

$DownloadUrl = "https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025"

function Find-Iso {
    $isos = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue
    if (-not $isos) { return $null }
    # 実ファイル名は "26100...SERVER_EVAL_x64FRE_ja-jp.iso" 等で "2025" を含まないため
    # SERVER_EVAL / SERVER_ を優先キーにする。
    $pref = $isos | Where-Object { $_.Name -match '(?i)(SERVER_EVAL|server.*2025|2025.*server|_SERVER_)' } | Select-Object -First 1
    if ($pref) { return $pref }
    return ($isos | Select-Object -First 1)
}

function Test-Iso($iso) {
    # マウントして install.wim / install.esd の有無とエディション一覧を確認
    $result = [ordered]@{ ok = $false; sizeGB = [math]::Round($iso.Length/1GB,2); editions = @(); error = $null }
    if ($iso.Length -lt 3GB) { $result.error = "ファイルが小さすぎます ($($result.sizeGB)GB)。ダウンロードが不完全な可能性があります。"; return $result }
    try {
        $img = Mount-DiskImage -ImagePath $iso.FullName -PassThru
        $vol = ($img | Get-Volume).DriveLetter
        $wim = @("$vol`:\sources\install.wim", "$vol`:\sources\install.esd") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $wim) { $result.error = "sources\install.wim/esd が見つかりません。Windows Server の ISO ではない可能性があります。" }
        else {
            try { $result.editions = @(Get-WindowsImage -ImagePath $wim | ForEach-Object { $_.ImageName }) } catch {}
            $result.ok = $true
        }
    } catch {
        $result.error = "ISO のマウントに失敗しました: $($_.Exception.Message)"
    } finally {
        Dismount-DiskImage -ImagePath $iso.FullName -ErrorAction SilentlyContinue | Out-Null
    }
    return $result
}

function Show-Guide {
    $w = "White"; $c = "Cyan"; $y = "Yellow"; $g = "Green"
    Write-Host ""
    Write-Host "  ┌────────────────────────────────────────────────────────────────────┐" -ForegroundColor $c
    Write-Host "  │  Windows Server 2025 評価版 ISO の配置が必要です                    │" -ForegroundColor $c
    Write-Host "  └────────────────────────────────────────────────────────────────────┘" -ForegroundColor $c
    Write-Host ""
    Write-Host "  Windows の VM を作るには Windows Server 2025 の評価版 ISO が 1 つ必要です。" -ForegroundColor $w
    Write-Host "  ライセンス条項への同意が必要なため、ダウンロードだけは手動でお願いします" -ForegroundColor $w
    Write-Host "  (Ubuntu は自動取得するので操作不要です)。下の手順で配置してください。" -ForegroundColor $w
    Write-Host ""
    Write-Host "  ── 手順 ───────────────────────────────────────────────────────────────" -ForegroundColor $c
    Write-Host ""
    Write-Host "  [1] ブラウザで次の URL を開く:" -ForegroundColor $w
    Write-Host "      $DownloadUrl" -ForegroundColor $g
    Write-Host ""
    Write-Host "  [2] 登録フォームに入力する (氏名・メール・会社名・国 など)。" -ForegroundColor $w
    Write-Host "      ※ 無償・180 日評価版です。職場メールが弾かれる場合があります。" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [3] ダウンロード形式の選択で  [ ISO ]  を選ぶ (VHD / Azure ではなく)。" -ForegroundColor $w
    Write-Host "      言語は  English (または日本語)  を選択 → ダウンロード開始。" -ForegroundColor $w
    Write-Host "      ファイルは約 5〜6GB、名前は例:" -ForegroundColor DarkGray
    Write-Host "        26100.x.xxxxxx-xxxx_SERVER_EVAL_x64FRE_en-us.iso" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [4] ダウンロードした .iso を次のフォルダに置く (ファイル名は任意):" -ForegroundColor $w
    Write-Host "      $IsoDir" -ForegroundColor $g
    Write-Host ""
    Write-Host "  ────────────────────────────────────────────────────────────────────────" -ForegroundColor $c
    Write-Host ""
}

# --- メイン ---
$iso = Find-Iso
if ($iso) {
    Write-Host "  [iso] 検出: $($iso.Name)  — 妥当性を検証します..." -ForegroundColor DarkCyan
    $v = Test-Iso $iso
    if ($v.ok) {
        Write-Host "  [iso] OK ($($v.sizeGB)GB)。含まれるエディション:" -ForegroundColor Green
        foreach ($e in $v.editions) { Write-Host "         - $e" -ForegroundColor DarkGray }
        exit 0
    }
    Write-Host "  [iso] 検証に失敗: $($v.error)" -ForegroundColor Yellow
    Write-Host "  [iso] 正しい Windows Server 2025 評価版 ISO を置き直してください。" -ForegroundColor Yellow
}

Show-Guide

if ($NoWait) {
    Write-Host "  ISO を配置したら、もう一度同じコマンドを実行してください。" -ForegroundColor Yellow
    Write-Host ""
    exit 3
}

# ポーリング待機
Write-Host "  ISO の配置を待っています... (最大 ${TimeoutMinutes} 分 / ${PollSeconds} 秒ごとに確認)" -ForegroundColor Yellow
Write-Host "  配置すると自動で検出・検証して次に進みます。中断する場合は Ctrl+C。" -ForegroundColor DarkGray
Write-Host ""
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollSeconds
    $iso = Find-Iso
    if ($iso) {
        Write-Host "  [iso] 検出: $($iso.Name)  — 検証します..." -ForegroundColor DarkCyan
        $v = Test-Iso $iso
        if ($v.ok) {
            Write-Host "  [iso] OK ($($v.sizeGB)GB)。次に進みます。" -ForegroundColor Green
            foreach ($e in $v.editions) { Write-Host "         - $e" -ForegroundColor DarkGray }
            exit 0
        }
        Write-Host "  [iso] まだ有効ではありません: $($v.error)" -ForegroundColor Yellow
        Write-Host "  [iso] 引き続き待機します..." -ForegroundColor DarkGray
    }
}
Write-Host "  タイムアウトしました。ISO を配置してから再実行してください。" -ForegroundColor Red
exit 3
