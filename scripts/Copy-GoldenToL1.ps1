#Requires -Version 5.1
<#
.SYNOPSIS
  ホスト側 (L0) から golden/ベース VHDX を Nested ホスト (L1) の中へ配送する。

.DESCRIPTION
  L2 VM は L1 の中で golden VHDX をコピーして作られる。その golden の実体は
  L0 の assets/ にあるため、まず L1 の中へ運び込む必要がある。

  本スクリプトは原則① (Hyper-V があるだけ / ネットワーク非依存) を守るため、
  物理 NW ではなく Hyper-V の VMBus 経由で転送する:
    - 実体転送      : Copy-VMFile (Guest Service Interface 経由・大容量に最適・資格情報不要)
    - 冪等性チェック : PowerShell Direct セッション (Test-Path + サイズ比較) のみに使用

  既に同一サイズで配送済みならスキップする (冪等)。サイズ不一致なら作り直す。

.PARAMETER VMName
  配送先の L1 VM 名。既定は build/resolved.json の l1.name。

.PARAMETER Source
  配送する VHDX の絶対パス (複数可)。既定は assets/win2025-golden.vhdx。

.PARAMETER DestDir
  L1 内の配置先ディレクトリ。group_vars/all.yml の l1_images_dir と一致させること。

.PARAMETER L1User / L1Password
  冪等性チェック用の PowerShell Direct 資格情報。既定は golden に焼いた既定管理者。

.EXAMPLE
  scripts\Copy-GoldenToL1.ps1
  scripts\Copy-GoldenToL1.ps1 -Source D:\...\assets\win2025-golden.vhdx,D:\...\assets\ubuntu2404-cloudimg.vhdx
#>
[CmdletBinding()]
param(
    [string]$VMName,
    [string[]]$Source,
    [string]$DestDir = "L:\images",
    [string]$L1User = "Administrator",
    [string]$L1Password = "P@ssw0rd-Lab-Change!",
    [int]$ReadyTimeoutSec = 600
)
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
function Log($m){ Write-Host "  [golden] $m" -ForegroundColor DarkCyan }

# --- 既定値の解決 ---
if (-not $VMName) {
    $model = Join-Path $RepoRoot "build\resolved.json"
    if (Test-Path $model) { $VMName = (Get-Content $model -Raw | ConvertFrom-Json).l1.name }
    if (-not $VMName) { throw "VMName を解決できません。-VMName を指定してください。" }
}
if (-not $Source) {
    $g = Join-Path $RepoRoot "assets\win2025-golden.vhdx"
    if (-not (Test-Path $g)) { throw "既定の golden が見つかりません: $g (-Source で指定してください)" }
    $Source = @($g)
}
foreach ($s in $Source) { if (-not (Test-Path $s)) { throw "ソースが存在しません: $s" } }

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { throw "L1 VM '$VMName' が L0 上に存在しません。先に L1 を作成してください。" }
if ($vm.State -ne 'Running') { Log "L1 '$VMName' を起動"; Start-VM -Name $VMName | Out-Null }

# --- Guest Service Interface を有効化 (Copy-VMFile の前提) ---
# 統合コンポーネント名はホストのロケールで変わる (日本語=「ゲスト サービス インターフェイス」)
# ため、ロケール非依存の既知 ID (6C09BB55-...) で特定する。原則③ 環境非依存。
$GSI_ID = "6C09BB55-D683-4DA0-8931-C9BF705F6480"
$gsi = Get-VMIntegrationService -VMName $VMName | Where-Object { $_.Id -match $GSI_ID }
if ($gsi -and -not $gsi.Enabled) {
    Log "Guest Service Interface (VM 統合) を有効化"
    $gsi | Enable-VMIntegrationService
}

# --- PowerShell Direct セッションが張れるまで待機 (冪等性チェック用) ---
$sec = (ConvertTo-SecureString $L1Password -AsPlainText -Force)
$cred = New-Object System.Management.Automation.PSCredential($L1User, $sec)
Log "L1 への PowerShell Direct セッションを待機 (最大 ${ReadyTimeoutSec}s)"
$deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
$session = $null
while (-not $session -and (Get-Date) -lt $deadline) {
    try { $session = New-PSSession -VMName $VMName -Credential $cred -ErrorAction Stop }
    catch { Start-Sleep -Seconds 10 }
}
if (-not $session) { throw "L1 へ PowerShell Direct セッションを張れませんでした (資格情報/起動状態を確認)。" }

try {
    # ゲスト内の Hyper-V Guest Service (vmicguestinterface) を起動。
    # golden では既定 Manual/停止のため、Copy-VMFile が "デバイスの準備ができていません"
    # (0x80070015) で失敗する。Automatic + 起動に収束させる。
    Log "ゲスト内 vmicguestinterface サービスを起動 (Copy-VMFile の前提)"
    Invoke-Command -Session $session -ScriptBlock {
        Set-Service -Name vmicguestinterface -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name vmicguestinterface -ErrorAction SilentlyContinue
        (Get-Service vmicguestinterface).Status.ToString()
    } | ForEach-Object { Log "  vmicguestinterface = $_" }

    # 配置先ディレクトリを確保
    Invoke-Command -Session $session -ScriptBlock {
        param($d) if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    } -ArgumentList $DestDir

    foreach ($s in $Source) {
        $name = Split-Path $s -Leaf
        $dest = Join-Path $DestDir $name
        $localLen = (Get-Item $s).Length

        # 冪等性: 既に同一サイズで存在すればスキップ
        $remoteLen = Invoke-Command -Session $session -ScriptBlock {
            param($p) if (Test-Path $p) { (Get-Item $p).Length } else { -1 }
        } -ArgumentList $dest

        if ($remoteLen -eq $localLen) {
            Log "$name は配送済み (同一サイズ $([math]::Round($localLen/1GB,1)) GB) -> スキップ"
            continue
        }
        if ($remoteLen -ge 0) {
            Log "$name はサイズ不一致 (L1=$remoteLen / L0=$localLen) -> 作り直し"
            Invoke-Command -Session $session -ScriptBlock { param($p) Remove-Item -LiteralPath $p -Force } -ArgumentList $dest
        }

        Log "$name を Copy-VMFile で L1 へ転送中 ($([math]::Round($localLen/1GB,1)) GB)... フォアグラウンドで待機"
        $t0 = Get-Date
        # ゲストサービスが ready になるまで "デバイスの準備ができていません" で弾かれることがある。
        # 最大 ReadyTimeoutSec の範囲でリトライしてから本転送に入る。
        $copied = $false; $copyDeadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
        while (-not $copied) {
            try {
                Copy-VMFile -VMName $VMName -SourcePath $s -DestinationPath $dest -FileSource Host -CreateFullPath -ErrorAction Stop
                $copied = $true
            } catch {
                if (($_.Exception.Message -match '0x80070015|準備ができていません|not ready') -and (Get-Date) -lt $copyDeadline) {
                    Log "  ゲストサービス準備待ち... 10s 後に再試行"
                    Start-Sleep -Seconds 10
                } else { throw }
            }
        }
        $elapsed = [math]::Round(((Get-Date)-$t0).TotalMinutes,1)

        # 転送後の検証
        $after = Invoke-Command -Session $session -ScriptBlock {
            param($p) if (Test-Path $p) { (Get-Item $p).Length } else { -1 }
        } -ArgumentList $dest
        if ($after -ne $localLen) { throw "$name の転送後サイズが不一致 (L1=$after / L0=$localLen)" }
        Log "$name 転送完了 (${elapsed} 分) -> $dest"
    }
}
finally {
    if ($session) { Remove-PSSession $session }
}
Log "golden 配送 完了"
exit 0
