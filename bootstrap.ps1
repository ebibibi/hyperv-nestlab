#Requires -Version 5.1
<#
.SYNOPSIS
  Nested Hyper-V IaC 基盤の唯一のエントリポイント。

.DESCRIPTION
  「利用者が用意するのは Hyper-V サーバーだけ」(原則①) を守るため、
  このスクリプトが必要な制御環境を自前でブートストラップする。

  処理の流れ:
    1. プリフライト   : Hyper-V / Python / 設定ファイルの存在確認
    2. 検証           : JSON Schema + 意味検証 (tools/resolve.py) で fail-fast
    3. 解決           : L1+L2 を確定モデル build/resolved.json へ展開
    4. 制御ノード構築 : 固定イメージから制御 VM を冪等に作成 (Ansible 内蔵)
    5. ハンドオフ     : 確定モデル / secrets を渡し、以降の構築を Ansible に委譲

  -DryRun を付けると 1〜3 のみ実行し、作成される環境のプランを表示する
  (VM は 1 台も作らない。安全な検証用)。

.EXAMPLE
  .\bootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\fileserver-s2d.yml -DryRun

.EXAMPLE
  .\bootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\fileserver-s2d.yml -VaultPassword (Read-Host -AsSecureString)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $L1,
    [Parameter(Mandatory)] [string] $L2,
    [switch] $DryRun,
    [securestring] $VaultPassword,
    [string] $Secrets = "secrets.yml",
    [string] $BuildDir = "build",
    # golden に焼く L1/L2 ローカル管理者パスワード。L1/L2 への PowerShell Direct にも使う。
    [string] $GoldenAdminPassword = "P@ssw0rd-Lab-Change!"
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$Resolved = Join-Path $RepoRoot "$BuildDir\resolved.json"

function Write-Step  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  OK  $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "  !!  $m" -ForegroundColor Yellow }
function Fail        { param($m) Write-Host "  NG  $m" -ForegroundColor Red; exit 1 }

function Resolve-Python {
    foreach ($c in @("python", "python3", "py")) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) {
            try { & $cmd.Source -c "import yaml, jsonschema" 2>$null; if ($LASTEXITCODE -eq 0) { return $cmd.Source } } catch {}
        }
    }
    return $null
}

# ---------------------------------------------------------------- 1. Preflight
Write-Step "プリフライト"

if (-not (Get-Module -ListAvailable Hyper-V)) {
    Fail "Hyper-V モジュールが見つかりません。このホストで Hyper-V 役割を有効化してください (原則①の唯一の前提)。"
}
Write-Ok "Hyper-V モジュールあり"

$L1Path = Join-Path $RepoRoot $L1
$L2Path = Join-Path $RepoRoot $L2
if (-not (Test-Path $L1Path)) { Fail "L1 ファイルが見つかりません: $L1Path" }
if (-not (Test-Path $L2Path)) { Fail "L2 ファイルが見つかりません: $L2Path" }
Write-Ok "設定ファイルあり ($L1 / $L2)"

$Python = Resolve-Python
if (-not $Python) {
    Fail "Python (pyyaml + jsonschema) が見つかりません。制御環境のブートストラップにはコンパクトな Python が必要です。"
}
Write-Ok "Python: $Python"

# ---------------------------------------------------------------- 2. 検証 + 3. 解決
Write-Step "検証 + 解決 (tools/resolve.py)"
$resolveScript = Join-Path $RepoRoot "tools\resolve.py"
& $Python $resolveScript --l1 $L1Path --l2 $L2Path --out $Resolved
if ($LASTEXITCODE -ne 0) { Fail "設定の検証/解決に失敗しました。上のエラーを修正してください。" }
Write-Ok "確定モデル: $Resolved"

# プラン表示
$model = Get-Content $Resolved -Raw | ConvertFrom-Json
Write-Host ""
Write-Host "----------------- 構築プラン -----------------" -ForegroundColor Magenta
Write-Host ("L1 ホスト : {0}  (vCPU {1} / {2}GB / nested={3})" -f $model.l1.name, $model.l1.cpu, $model.l1.memory_gb, $model.l1.nested)
Write-Host ("NAT       : {0}  subnet={1}  gw={2}" -f $model.l1.nat.switch, $model.l1.nat.subnet, $model.l1.nat.host_ip)
if ($model.domain) { Write-Host ("ドメイン  : {0} (NetBIOS {1})" -f $model.domain.fqdn, $model.domain.netbios) }
Write-Host ("L2 VM     : {0} 台" -f $model.vms.Count)
foreach ($vm in $model.vms) {
    $dataCount = @($vm.disks | Where-Object { $_.role -eq 'data' }).Count
    $ip = if ($vm.nics) { $vm.nics[0].ip } else { "-" }
    $roles = ($vm.provision.roles) -join ","
    Write-Host ("   - {0,-8} ip={1,-12} vCPU={2} mem={3}GB data-disks={4} roles=[{5}]" -f $vm.name, $ip, $vm.cpu, $vm.memory_gb, $dataCount, $roles)
}
if ($model.clusters.Count -gt 0) {
    Write-Host ("クラスタ  : {0} 個" -f $model.clusters.Count)
    foreach ($cl in $model.clusters) {
        Write-Host ("   - {0} ip={1} nodes=[{2}] s2d={3}" -f $cl.name, $cl.ip, ($cl.nodes -join ","), $cl.s2d)
    }
}
Write-Host "----------------------------------------------" -ForegroundColor Magenta
Write-Host ""

# 必要イメージの算出 (制御ノード=Ubuntu 固定 + L1=Windows golden + L2 の OS 別)
$assetsDir = Join-Path $RepoRoot "assets"
$need = [ordered]@{}
$need["ubuntu2404-cloudimg.vhdx"] = "linux"   # 制御ノード用に常時必要
foreach ($vm in $model.vms) {
    switch -Regex ($vm.os) {
        'ubuntu|debian|linux' { $need["ubuntu2404-cloudimg.vhdx"] = "linux" }
        'windows'             { $need["win2025-golden.vhdx"] = "windows" }
    }
}
if ($model.l1.base_image) { $need["win2025-golden.vhdx"] = "windows" }

Write-Host "必要イメージ:" -ForegroundColor Magenta
$missing = @()
foreach ($img in $need.Keys) {
    $p = Join-Path $assetsDir $img
    if (Test-Path $p) { Write-Host ("   [OK]   {0}" -f $img) -ForegroundColor Green }
    else { Write-Host ("   [未]   {0}  ({1})" -f $img, $need[$img]) -ForegroundColor Yellow; $missing += $need[$img] }
}
Write-Host ""

if ($DryRun) {
    if ($missing) {
        Write-Host "  DryRun: 未整備のイメージがあります。本番実行時に自動取得/ビルドします" -ForegroundColor DarkGray
        if ($missing -contains "windows") {
            Write-Host "    - Windows: Server 2025 評価版 ISO の配置が必要です。本番実行時に手順を案内します。" -ForegroundColor DarkGray
            Write-Host "               先に確認/配置するには: .\scripts\Wait-WindowsIso.ps1 -NoWait" -ForegroundColor DarkGray
        }
        if ($missing -contains "linux")   { Write-Host "    - Linux: 固定 URL から自動ダウンロード+変換 (操作不要)" -ForegroundColor DarkGray }
    }
    Write-Ok "DryRun: 検証と解決のみ完了しました。VM は作成していません。"
    Write-Host "  本番実行は -DryRun を外して再実行してください。" -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------- 4-pre. イメージ整備
Write-Step "golden イメージの整備 (冪等)"
if ($need.Keys -contains "ubuntu2404-cloudimg.vhdx" -and -not (Test-Path (Join-Path $assetsDir "ubuntu2404-cloudimg.vhdx"))) {
    & (Join-Path $RepoRoot "scripts\Get-UbuntuImage.ps1") -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { Fail "Ubuntu イメージの整備に失敗しました。" }
}
if ($need.Keys -contains "win2025-golden.vhdx" -and -not (Test-Path (Join-Path $assetsDir "win2025-golden.vhdx"))) {
    # ISO 配置をガイド + 配置されるまで待機・検証 (原則① の唯一の手動ステップ)
    & (Join-Path $RepoRoot "scripts\Wait-WindowsIso.ps1") -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { Fail "Windows Server 2025 ISO が未配置です。上のガイドに従い assets\iso\ に ISO を置いて再実行してください。" }
    # DISM 標準ツールで golden を生成 (oscdimg/ADK 不要 = 原則①)。
    & (Join-Path $RepoRoot "scripts\Build-WindowsGoldenDism.ps1") -AdminPassword $GoldenAdminPassword
    $rc = $LASTEXITCODE
    if ($rc -eq 3) { Fail "Windows ISO 未配置のため中断しました。assets\iso\ に ISO を置いて再実行してください。" }
    if ($rc -ne 0) { Fail "Windows golden イメージのビルドに失敗しました。" }
}
Write-Ok "イメージ整備完了"

# ---------------------------------------------------------------- 4a. L0 -> L1
Write-Step "L0 -> L1  Nested ホストの冪等プロビジョニング (PowerShell)"
$hostProv = Join-Path $RepoRoot "scripts\Invoke-HostProvision.ps1"
& $hostProv -RepoRoot $RepoRoot -Model $Resolved
if ($LASTEXITCODE -ne 0) { Fail "L1 ホストのプロビジョニングに失敗しました。" }
Write-Ok "L1 ホスト準備完了"

# ---------------------------------------------------------------- 4b. ホスト WinRM
Write-Step "ホスト(L0) WinRM を制御 VM から操作可能な状態へ収束"
& (Join-Path $RepoRoot "scripts\Ensure-HostWinRM.ps1")
if ($LASTEXITCODE -ne 0) { Fail "ホスト WinRM の収束に失敗しました。" }
& (Join-Path $RepoRoot "scripts\Ensure-LabServiceUser.ps1") -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { Fail "ラボ用サービスユーザーの作成に失敗しました。" }
Write-Ok "ホスト WinRM 準備完了"

# ---------------------------------------------------------------- 4c. 制御ノード
Write-Step "制御ノード (Ansible 内蔵 VM) の冪等構築 + 疎通確認"
$ensureCtrl = Join-Path $RepoRoot "control-node\Ensure-ControlNode.ps1"
if (-not (Test-Path $ensureCtrl)) { Fail "制御ノード構築スクリプトが見つかりません: $ensureCtrl" }
& $ensureCtrl -RepoRoot $RepoRoot -Model $Resolved -WaitReady
if ($LASTEXITCODE -ne 0) { Fail "制御ノードの構築に失敗しました。" }
Write-Ok "制御ノード準備完了 (Ansible 動作確認済み)"

# ---------------------------------------------------------------- 4d. 本線疎通
Write-Step "本線疎通確認: 制御 VM -> WinRM -> ホスト Hyper-V"
& (Join-Path $RepoRoot "control-node\Invoke-Ansible.ps1") -RepoRoot $RepoRoot -Model $Resolved -Playbook "ping_l0.yml"
if ($LASTEXITCODE -ne 0) { Fail "本線(制御 VM -> ホスト)の疎通に失敗しました。" }
Write-Ok "本線疎通 OK"

# ---------------------------------------------------------------- 4e. L1 ラボストア
Write-Step "L1 にラボストア(L:)を増設・初期化 (golden/L2 の置き場)"
& (Join-Path $RepoRoot "scripts\Add-L1LabStore.ps1") -L1Password $GoldenAdminPassword
if ($LASTEXITCODE -ne 0) { Fail "L1 ラボストアの構成に失敗しました。" }
Write-Ok "ラボストア準備完了"

# ---------------------------------------------------------------- 4f. golden を L1 へ配送
Write-Step "golden / ベースイメージを L1 (L:\images) へ配送 (PowerShell Direct)"
$delivery = @()
if ($need.Keys -contains "win2025-golden.vhdx")     { $delivery += (Join-Path $assetsDir "win2025-golden.vhdx") }
if ($need.Keys -contains "ubuntu2404-cloudimg.vhdx" -and ($model.vms | Where-Object { $_.os -match 'ubuntu|debian|linux' })) {
    $delivery += (Join-Path $assetsDir "ubuntu2404-cloudimg.vhdx")
}
if ($delivery) {
    & (Join-Path $RepoRoot "scripts\Copy-GoldenToL1.ps1") -Source $delivery -L1Password $GoldenAdminPassword
    if ($LASTEXITCODE -ne 0) { Fail "golden の L1 配送に失敗しました。" }
}
Write-Ok "イメージ配送完了"

# ---------------------------------------------------------------- 4g. L1 内 Hyper-V + NAT
Write-Step "L1 内に Hyper-V 役割 + LabNAT を構成 (Ansible: setup_l1.yml)"
& (Join-Path $RepoRoot "control-node\Invoke-Ansible.ps1") -RepoRoot $RepoRoot -Model $Resolved -Playbook "setup_l1.yml" -L1Password $GoldenAdminPassword
if ($LASTEXITCODE -ne 0) { Fail "L1 内 Hyper-V/NAT の構成に失敗しました。" }
Write-Ok "L1 内ネットワーク準備完了"

# ---------------------------------------------------------------- 4h. Linux シード配送
if ($model.vms | Where-Object { $_.os -match 'ubuntu|debian|linux' }) {
    Write-Step "Linux L2 の cloud-init シードを生成し L1 へ配送"
    & (Join-Path $RepoRoot "scripts\Publish-L2Seeds.ps1") -RepoRoot $RepoRoot -Model $Resolved -L1Password $GoldenAdminPassword
    if ($LASTEXITCODE -ne 0) { Fail "cloud-init シードの配送に失敗しました。" }
    Write-Ok "シード配送完了"
}

# ---------------------------------------------------------------- 5. L2 作成
Write-Step "L1 -> L2  仮想マシン群の作成 (Ansible: create_l2.yml)"
& (Join-Path $RepoRoot "control-node\Invoke-Ansible.ps1") -RepoRoot $RepoRoot -Model $Resolved -Playbook "create_l2.yml" -L1Password $GoldenAdminPassword
if ($LASTEXITCODE -ne 0) { Fail "L2 VM の作成に失敗しました。" }
Write-Ok "L2 VM 作成完了"

# ---------------------------------------------------------------- 6. AD フォレスト
if ($model.domain) {
    Write-Step "L2 上に Active Directory フォレストを構築 (L1踏み台 PowerShell Direct)"
    & (Join-Path $RepoRoot "scripts\Initialize-AdForest.ps1") -RepoRoot $RepoRoot -ModelPath $Resolved -L1Password $GoldenAdminPassword -GuestPassword $GoldenAdminPassword
    if ($LASTEXITCODE -ne 0) { Fail "AD フォレストの構築に失敗しました。" }
    Write-Ok "AD フォレスト構築完了"
}

Write-Host ""
Write-Ok "完了: 宣言した環境が一括で構築されました (L1 -> L2 -> AD)。"
Write-Host "  再実行すれば全工程が冪等に収束します (no-change が受け入れ条件)。" -ForegroundColor DarkGray
