#Requires -Version 5.1
<#
.SYNOPSIS
  Nested Hyper-V IaC 基盤の唯一のエントリポイント。

.DESCRIPTION
  「利用者が用意するのは Hyper-V サーバーだけ」(原則①) を守るため、
  このスクリプトが必要な制御環境を自前でブートストラップする。

  処理の流れ (PowerShell / PowerShell Direct と Ansible のハイブリッド。
  境界は「対象に IP+WinRM が在るか」— 整うまでと L0 は PowerShell、整った後の内側は Ansible):
    1. プリフライト/検証/解決 : Hyper-V/Python 確認 + tools/resolve.py で確定モデル化  …PowerShell+Python
    2. イメージ整備           : Windows golden を DISM 生成 / Ubuntu 取得              …PowerShell
    3. L0→L1 / 制御VM 構築    : L1・制御VMを作成、L0 WinRM 収束                        …PowerShell(+PS Direct)
    4. L1 到達化              : 静的IP/WinRM/RDP/改名/キーボードを焼く                 …PowerShell Direct
    5. L1 内部構成            : Hyper-V役割+LabNAT(setup_l1) → ラボストア/golden配送    …Ansible / PowerShell
    6. L2 作成 + アクセス初期化: create_l2(Ansible) → 静的IP/WinRM/CredSSP(PS Direct)   …Ansible / PS Direct
    7. AD / クラスタ          : AD 昇格(PS Direct, 二段ホップ) / S2D(create_cluster)    …PS Direct / Ansible
  完了時にフェーズ別の構築時間と接続情報を表示する。環境の削除は teardown.ps1。

  -DryRun を付けると 1 (検証/解決) のみ実行し、作成される環境のプランを表示する
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

# ---- 構築時間の計測 (フェーズ境界は Write-Step が自動でマークする) ----
$script:BuildSw       = [System.Diagnostics.Stopwatch]::StartNew()
$script:Phases        = New-Object System.Collections.Generic.List[object]
$script:CurPhase      = $null
$script:CurPhaseStart = 0.0
function Format-Duration { param([double]$Sec)
    if ($Sec -lt 60) { return ('{0:0.0}s' -f $Sec) }
    $ts = [TimeSpan]::FromSeconds([math]::Round($Sec))
    if ($ts.TotalHours -ge 1) { return ('{0}h{1:00}m{2:00}s' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds) }
    return ('{0}m{1:00}s' -f [int]$ts.TotalMinutes, $ts.Seconds)
}
function Close-Phase {
    if ($script:CurPhase) {
        $script:Phases.Add([pscustomobject]@{ Name = $script:CurPhase; Seconds = ($script:BuildSw.Elapsed.TotalSeconds - $script:CurPhaseStart) })
        $script:CurPhase = $null
    }
}
function Write-BuildTime {
    Close-Phase
    Write-Host ""
    Write-Host "=============== 構築時間 (フェーズ別) ===============" -ForegroundColor Magenta
    foreach ($p in $script:Phases) { Write-Host ("  {0,-44} {1,10}" -f $p.Name, (Format-Duration $p.Seconds)) }
    Write-Host ("  {0,-44} {1,10}" -f ('-' * 44), ('-' * 10)) -ForegroundColor DarkGray
    Write-Host ("  {0,-44} {1,10}" -f '合計', (Format-Duration $script:BuildSw.Elapsed.TotalSeconds)) -ForegroundColor Green
    Write-Host "====================================================" -ForegroundColor Magenta
}

function Write-Step  { param($m) Close-Phase; $script:CurPhase = $m; $script:CurPhaseStart = $script:BuildSw.Elapsed.TotalSeconds; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  OK  $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "  !!  $m" -ForegroundColor Yellow }
function Fail        { param($m) Write-Host "  NG  $m" -ForegroundColor Red; Write-Host ("  経過時間: {0}" -f (Format-Duration $script:BuildSw.Elapsed.TotalSeconds)) -ForegroundColor DarkGray; exit 1 }

function Write-ConnectionInfo {
    param(
        [Parameter(Mandatory)] $Model,
        [Parameter(Mandatory)] [string] $AdminPassword
    )

    $hostCredPath = Join-Path $RepoRoot "build\host-cred.json"
    $sshKeyPath = Join-Path $RepoRoot "build\ssh\id_ed25519"
    $hostCred = if (Test-Path $hostCredPath) {
        Get-Content $hostCredPath -Raw | ConvertFrom-Json
    } else {
        $null
    }

    Write-Host ""
    Write-Host "=============== 接続情報・認証情報 ===============" -ForegroundColor Magenta
    Write-Warn2 "以下には平文パスワードを表示します。画面共有・ログ保存時は取り扱いに注意してください。"

    if ($hostCred) {
        Write-Host ""
        Write-Host "[L0: 物理 Hyper-V ホスト]" -ForegroundColor Cyan
        Write-Host ("  接続先     : {0}:5985" -f $hostCred.host_addr)
        Write-Host "  実行元     : 制御 VM"
        Write-Host "  プロトコル : WinRM / HTTP / NTLM"
        Write-Host ("  ユーザー   : {0}" -f $hostCred.user)
        Write-Host ("  パスワード : {0}" -f $hostCred.password)
        Write-Host ("  接続例     : Enter-PSSession -ComputerName {0} -Authentication Negotiate -Credential (Get-Credential '{1}')" -f $hostCred.host_addr, $hostCred.user)
    } else {
        Write-Warn2 "L0 資格情報ファイルが見つかりません: $hostCredPath"
    }

    Write-Host ""
    Write-Host "[制御 VM]" -ForegroundColor Cyan
    Write-Host "  接続先     : 10.20.0.10:22"
    Write-Host "  実行元     : L0 物理ホスト"
    Write-Host "  プロトコル : SSH 公開鍵認証"
    Write-Host "  ユーザー   : labadmin"
    Write-Host ("  秘密鍵     : {0}" -f $sshKeyPath)
    Write-Host ("  接続例     : ssh -i `"{0}`" labadmin@10.20.0.10" -f $sshKeyPath)

    Write-Host ""
    Write-Host ("[L1: {0}]" -f $Model.l1.name) -ForegroundColor Cyan
    Write-Host "  接続先     : 10.20.0.20:5985"
    Write-Host "  実行元     : L0 物理ホストまたは制御 VM"
    Write-Host "  プロトコル : WinRM / HTTP / NTLM"
    Write-Host "  ユーザー   : Administrator"
    Write-Host ("  パスワード : {0}" -f $AdminPassword)
    Write-Host "  接続例     : Enter-PSSession -ComputerName 10.20.0.20 -Authentication Negotiate -Credential (Get-Credential 'Administrator')"
    Write-Host "  RDP (画面) : L0 から直接 → mstsc /v:10.20.0.20 (Administrator / 上記パスワード)"

    Write-Host ""
    Write-Host "[Hyper-V マネージャーで L2 VM を操作]" -ForegroundColor Cyan
    Write-Host "  1. L0 の Hyper-V マネージャーで L1 VM のコンソールを開く"
    Write-Host ("     GUI      : Hyper-V マネージャー > {0} > 接続" -f $Model.l1.name)
    Write-Host ("     コマンド : vmconnect.exe localhost `"{0}`"" -f $Model.l1.name)
    Write-Host "  2. L1 に Administrator でサインイン"
    Write-Host ("     パスワード: {0}" -f $AdminPassword)
    Write-Host "  3. L1 内で Hyper-V マネージャー (virtmgmt.msc) を開く"
    Write-Host "     VM 一覧  : Get-VM"
    if (@($Model.vms).Count -gt 0) {
        Write-Host ("     L2 VM    : {0}" -f ((@($Model.vms) | ForEach-Object { $_.name }) -join ", "))
        Write-Host "     接続例   : vmconnect.exe localhost `"<L2 VM 名>`""
    } else {
        Write-Host "     L2 VM    : なし"
    }
    Write-Host "  ※ L2 の電源・設定・コンソール操作は L1 内の Hyper-V マネージャーで行います。"
    Write-Host "  ※ GUI を快適に使うなら RDP チェーン: L0→L1 (mstsc /v:10.20.0.20)→ L1 内から L2 へ mstsc /v:<L2 IP>"
    Write-Host "     (RDP は L1/L2 とも既定で有効化済み。L2 は LabNAT 隔離のため必ず L1 の中から接続)"

    foreach ($vm in @($Model.vms)) {
        $ip = if ($vm.nics -and $vm.nics[0].ip) { $vm.nics[0].ip } else { "(IP 未設定)" }
        $guestIsLinux = $vm.os -match "ubuntu|debian|linux|rocky|alma"

        Write-Host ""
        Write-Host ("[L2: {0}]" -f $vm.name) -ForegroundColor Cyan
        Write-Host ("  コンソール : L1 内で vmconnect.exe localhost `"{0}`"" -f $vm.name)
        if ($guestIsLinux) {
            Write-Host ("  接続先     : {0}:22" -f $ip)
            Write-Host "  実行元     : 制御 VM"
            Write-Host "  プロトコル : SSH 公開鍵認証"
            Write-Host "  ユーザー   : labadmin"
            Write-Host ("  秘密鍵     : {0}" -f $sshKeyPath)
            Write-Host ("  接続例     : ssh -i `"{0}`" labadmin@{1}" -f $sshKeyPath, $ip)
        } else {
            $isDomainMember = $Model.domain -and ($vm.domain_join -or $vm.provision.forest)
            $user = if ($isDomainMember) { "$($Model.domain.netbios)\Administrator" } else { "Administrator" }
            $transport = if ($isDomainMember) { "WinRM / HTTP / CredSSP または NTLM" } else { "WinRM / HTTP / NTLM" }
            Write-Host ("  接続先     : {0}:5985" -f $ip)
            Write-Host "  実行元     : 制御 VM"
            Write-Host ("  プロトコル : {0}" -f $transport)
            Write-Host ("  ユーザー   : {0}" -f $user)
            Write-Host ("  パスワード : {0}" -f $AdminPassword)
            Write-Host ("  接続例     : Enter-PSSession -ComputerName {0} -Authentication Negotiate -Credential (Get-Credential '{1}')" -f $ip, $user)
            Write-Host ("  RDP (画面) : L1 の中から → mstsc /v:{0} ({1} / 上記パスワード)  ※LabNAT 隔離のため L1 経由" -f $ip, $user)
        }
    }

    if ($Model.domain) {
        Write-Host ""
        Write-Host "[Active Directory]" -ForegroundColor Cyan
        Write-Host ("  ドメイン管理者 : {0}\Administrator" -f $Model.domain.netbios)
        Write-Host ("  パスワード     : {0}" -f $AdminPassword)
        Write-Host ("  DSRM パスワード: {0}" -f $Model.domain.dsrm_password)
    }

    Write-Host "====================================================" -ForegroundColor Magenta
}

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

# 必要イメージは resolver が images_needed として算出済み
#   (L1=en-us golden 固定 + L2 各言語の golden + Ubuntu)。制御ノードも Ubuntu を使う。
$assetsDir = Join-Path $RepoRoot "assets"
$needed = @($model.images_needed)
if (-not ($needed | Where-Object { $_.kind -eq 'linux' })) {
    $needed += [pscustomobject]@{ kind = 'linux'; vhdx = 'ubuntu2404-cloudimg.vhdx' }   # 制御ノード用
}

Write-Host "必要イメージ:" -ForegroundColor Magenta
$missing = @()
foreach ($img in $needed) {
    if ($img.kind -eq 'windows') { $file = $img.golden_file; $tag = "Windows golden [$($img.language)] $($img.label)" }
    else                         { $file = $img.vhdx;        $tag = "Linux (Ubuntu cloud image)" }
    if (Test-Path (Join-Path $assetsDir $file)) { Write-Host ("   [OK]   {0,-32} {1}" -f $file, $tag) -ForegroundColor Green }
    else { Write-Host ("   [未]   {0,-32} {1}" -f $file, $tag) -ForegroundColor Yellow; $missing += $img }
}
Write-Host ""

if ($DryRun) {
    if ($missing) {
        Write-Host "  DryRun: 未整備のイメージは本番実行時に自動取得/ビルドします (操作不要)" -ForegroundColor DarkGray
        foreach ($m in $missing) {
            if ($m.kind -eq 'windows') { Write-Host ("    - Windows[{0}]: 直リンク自動DL -> {1} を DISM 生成" -f $m.language, $m.golden_file) -ForegroundColor DarkGray }
            else                       { Write-Host  "    - Linux: Ubuntu cloud image を固定URL自動DL+変換" -ForegroundColor DarkGray }
        }
    }
    Write-Ok "DryRun: 検証と解決のみ完了しました。VM は作成していません。"
    Write-Host "  本番実行は -DryRun を外して再実行してください。" -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------- 4-pre. イメージ整備
Write-Step "イメージの整備 (冪等 / 言語別 golden を自動取得・生成)"
foreach ($img in $needed) {
    if ($img.kind -eq 'linux') {
        if (-not (Test-Path (Join-Path $assetsDir $img.vhdx))) {
            & (Join-Path $RepoRoot "scripts\Get-UbuntuImage.ps1") -RepoRoot $RepoRoot
            if ($LASTEXITCODE -ne 0) { Fail "Ubuntu イメージの整備に失敗しました。" }
        }
    } else {
        if (-not (Test-Path (Join-Path $assetsDir $img.golden_file))) {
            Write-Host ("  -> Windows[{0}] {1} を整備" -f $img.language, $img.golden_file) -ForegroundColor DarkCyan
            & (Join-Path $RepoRoot "scripts\Get-WindowsIso.ps1") -RepoRoot $RepoRoot -Url $img.iso_url -IsoName $img.iso_name
            if ($LASTEXITCODE -ne 0) { Fail "Windows ISO ($($img.language)) の自動ダウンロードに失敗しました。" }
            & (Join-Path $RepoRoot "scripts\Build-WindowsGoldenDism.ps1") -IsoName $img.iso_name -VhdxName $img.golden_file -AdminPassword $GoldenAdminPassword
            $rc = $LASTEXITCODE
            if ($rc -ne 0) { Fail "Windows golden ($($img.language)) のビルドに失敗しました (rc=$rc)。" }
        }
    }
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

# ---------------------------------------------------------------- 4d2. L1 を CtrlNAT へ + WinRM
# golden 由来の L1 は CtrlNAT 未接続 / 静的 IP 未設定 / WinRM 未構成のため、制御 VM から
# 到達できない。PowerShell Direct (VMBus) で L1 内に静的 IP と WinRM を焼き込み、以降の
# Ansible (setup_l1 等) が L1 (10.20.0.20) を WinRM で叩けるようにする。
Write-Step "L1 を CtrlNAT に接続し 静的IP/WinRM を構成 (PowerShell Direct)"
& (Join-Path $RepoRoot "scripts\Initialize-L1Network.ps1") -L1Password $GoldenAdminPassword
if ($LASTEXITCODE -ne 0) { Fail "L1 ネットワーク/WinRM の構成に失敗しました。" }
Write-Ok "L1 到達性 (CtrlNAT/WinRM) 準備完了"

# ---------------------------------------------------------------- 4e. L1 内 Hyper-V + NAT
# Hyper-V を L1 内に先に入れておく。ラボストアの Set-VMHost や L2 作成は L1 内 Hyper-V
# (Set-VMHost/New-VM 等) を使うため、ここを先行させないと「Set-VMHost が認識されない」で失敗する。
# setup_l1 は L:/golden に依存しないので先行させても安全 (Hyper-V 導入時に L1 が再起動することがある)。
Write-Step "L1 内に Hyper-V 役割 + LabNAT を構成 (Ansible: setup_l1.yml)"
& (Join-Path $RepoRoot "control-node\Invoke-Ansible.ps1") -RepoRoot $RepoRoot -Model $Resolved -Playbook "setup_l1.yml" -L1Password $GoldenAdminPassword
if ($LASTEXITCODE -ne 0) { Fail "L1 内 Hyper-V/NAT の構成に失敗しました。" }
Write-Ok "L1 内ネットワーク準備完了"

# ---------------------------------------------------------------- 4f. L1 ラボストア
Write-Step "L1 にラボストア(L:)を増設・初期化 (golden/L2 の置き場)"
& (Join-Path $RepoRoot "scripts\Add-L1LabStore.ps1") -L1Password $GoldenAdminPassword
if ($LASTEXITCODE -ne 0) { Fail "L1 ラボストアの構成に失敗しました。" }
Write-Ok "ラボストア準備完了"

# ---------------------------------------------------------------- 4g. golden を L1 へ配送
Write-Step "ベースイメージ(言語別 golden / Ubuntu)を L1 (L:\images) へ配送 (PowerShell Direct)"
# L2 が実際に使う言語の golden + (Linux L2 があれば)Ubuntu を配送。L1 用 en-us は L1 OS に使うため不要。
$delivery = @()
$l2langs = @($model.vms | Where-Object { $_.os -notmatch 'ubuntu|debian|linux' } | ForEach-Object { $_.base_image_file } | Select-Object -Unique)
foreach ($g in $l2langs) { $p = Join-Path $assetsDir $g; if (Test-Path $p) { $delivery += $p } }
if ($model.vms | Where-Object { $_.os -match 'ubuntu|debian|linux' }) {
    $u = Join-Path $assetsDir "ubuntu2404-cloudimg.vhdx"; if (Test-Path $u) { $delivery += $u }
}
$delivery = @($delivery | Select-Object -Unique)
if ($delivery) {
    & (Join-Path $RepoRoot "scripts\Copy-GoldenToL1.ps1") -Source $delivery -L1Password $GoldenAdminPassword
    if ($LASTEXITCODE -ne 0) { Fail "ベースイメージの L1 配送に失敗しました。" }
}
Write-Ok "イメージ配送完了"

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

# ---------------------------------------------------------------- 5b. L2 アクセス初期化
# Windows L2 に最小ブートストラップ (静的IP/改名/WinRM/CredSSP) を PowerShell Direct で焼く。
# これで制御 VM (L1 ルータ経由) から各 L2 へ Ansible で到達できるようになる。
if ($model.vms | Where-Object { $_.os -notmatch 'ubuntu|debian|linux' }) {
    Write-Step "Windows L2 のアクセス初期化 (静的IP/改名/WinRM/CredSSP, PowerShell Direct)"
    & (Join-Path $RepoRoot "scripts\Initialize-L2Access.ps1") -RepoRoot $RepoRoot -ModelPath $Resolved -L1Password $GoldenAdminPassword -GuestPassword $GoldenAdminPassword
    if ($LASTEXITCODE -ne 0) { Fail "Windows L2 のアクセス初期化に失敗しました。" }
    Write-Ok "Windows L2 アクセス初期化完了"
}

# ---------------------------------------------------------------- 6. AD フォレスト
if ($model.domain) {
    Write-Step "L2 上に Active Directory フォレストを構築 (L1踏み台 PowerShell Direct)"
    & (Join-Path $RepoRoot "scripts\Initialize-AdForest.ps1") -RepoRoot $RepoRoot -ModelPath $Resolved -L1Password $GoldenAdminPassword -GuestPassword $GoldenAdminPassword
    if ($LASTEXITCODE -ne 0) { Fail "AD フォレストの構築に失敗しました。" }
    Write-Ok "AD フォレスト構築完了"
}

# ---------------------------------------------------------------- 7. クラスタ + S2D
if ($model.clusters -and $model.clusters.Count -gt 0) {
    Write-Step "L2 上にフェイルオーバークラスタ + S2D を構築 (Ansible: create_cluster.yml)"
    & (Join-Path $RepoRoot "control-node\Invoke-Ansible.ps1") -RepoRoot $RepoRoot -Model $Resolved -Playbook "create_cluster.yml" -L1Password $GoldenAdminPassword
    if ($LASTEXITCODE -ne 0) { Fail "クラスタ/S2D の構築に失敗しました。" }
    Write-Ok "クラスタ + S2D 構築完了"
}

Write-Host ""
Write-Ok "完了: 宣言した環境が一括で構築されました (L1 -> L2 -> AD -> Cluster)。"
Write-Host "  再実行すれば全工程が冪等に収束します (no-change が受け入れ条件)。" -ForegroundColor DarkGray
Write-ConnectionInfo -Model $model -AdminPassword $GoldenAdminPassword
Write-BuildTime
