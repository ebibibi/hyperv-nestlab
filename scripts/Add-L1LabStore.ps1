#Requires -Version 5.1
<#
.SYNOPSIS
  L1 (Nested ホスト) に「ラボ用ストレージ」専用ディスクを増設し、golden / L2 VM の
  置き場として初期化する。

.DESCRIPTION
  L1 の OS ディスクは golden VHDX 由来で小さい (40GB) ため、golden の配送と
  L2 VM の作成で容量が枯渇する。そこで L1 に大容量の動的 VHDX を増設し、
  その上に golden と L2 を配置する設計に分離する (原則② 決定性 / 容量の確保)。

  本スクリプトは冪等:
    L0 側 : ラボストア VHDX を data 配下に作成し、未接続なら L1 へ SCSI ホットアド。
    L1 側 : RAW ディスクを GPT 初期化 -> NTFS フォーマット (ラベル LabStore) ->
            固定ドライブレター割当 -> images/vms フォルダ作成 ->
            既存 golden を OS ディスクからラボストアへ移動 ->
            Hyper-V 既定の VM/VHD 配置先をラボストアに設定。

  既に LabStore ボリュームがあれば初期化はスキップする。

.PARAMETER VMName        L1 VM 名 (既定: build/resolved.json の l1.name)
.PARAMETER SizeGB        ラボストアの最大サイズ (動的なので実消費は使用分のみ)
.PARAMETER DriveLetter   L1 内で割り当てるドライブレター (既定 L)
.PARAMETER L1User/L1Password  PowerShell Direct 資格情報 (既定: golden の管理者)
#>
[CmdletBinding()]
param(
    [string]$VMName,
    [int]$SizeGB = 300,
    [string]$DriveLetter = "L",
    [string]$L1User = "Administrator",
    [string]$L1Password = "P@ssw0rd-Lab-Change!",
    [int]$ReadyTimeoutSec = 300
)
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
function Log($m){ Write-Host "  [labstore] $m" -ForegroundColor DarkCyan }

# Get-LabDataRoot を取り込み (VHDX 配置先の自己完結ルート)
$mod = Join-Path $RepoRoot "scripts\HyperVLab.psm1.ps1"
if (Test-Path $mod) { . $mod }

if (-not $VMName) {
    $model = Join-Path $RepoRoot "build\resolved.json"
    if (Test-Path $model) { $VMName = (Get-Content $model -Raw | ConvertFrom-Json).l1.name }
    if (-not $VMName) { throw "VMName を解決できません。-VMName を指定してください。" }
}
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { throw "L1 VM '$VMName' が存在しません。" }
if ($vm.State -ne 'Running') { Log "L1 を起動"; Start-VM -Name $VMName | Out-Null }

# --- L0: ラボストア VHDX を作成 + ホットアド ---
$dataRoot = if (Get-Command Get-LabDataRoot -ErrorAction SilentlyContinue) { Get-LabDataRoot -RepoRoot $RepoRoot } else { Join-Path $RepoRoot "data" }
$vmDir = Join-Path (Join-Path $dataRoot "vms") $VMName
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
$storePath = Join-Path $vmDir "$VMName-labstore.vhdx"

if (-not (Test-Path $storePath)) {
    Log "ラボストア VHDX を作成 ($SizeGB GB 動的) -> $storePath"
    New-VHD -Path $storePath -SizeBytes ($SizeGB * 1GB) -Dynamic | Out-Null
}
$attached = Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -eq $storePath }
if (-not $attached) {
    Log "ラボストアを L1 へ SCSI ホットアド"
    Add-VMHardDiskDrive -VMName $VMName -Path $storePath -ControllerType SCSI
} else {
    Log "ラボストアは接続済み"
}

# --- L1: PowerShell Direct セッション ---
$cred = New-Object System.Management.Automation.PSCredential($L1User, (ConvertTo-SecureString $L1Password -AsPlainText -Force))
Log "L1 への PowerShell Direct セッションを待機"
$deadline = (Get-Date).AddSeconds($ReadyTimeoutSec); $session = $null
while (-not $session -and (Get-Date) -lt $deadline) {
    try { $session = New-PSSession -VMName $VMName -Credential $cred -ErrorAction Stop }
    catch { Start-Sleep -Seconds 8 }
}
if (-not $session) { throw "L1 へ PowerShell Direct セッションを張れませんでした。" }

try {
    $result = Invoke-Command -Session $session -ScriptBlock {
        param($Letter)
        $ErrorActionPreference = 'Stop'
        $out = @()

        # 既に LabStore ボリュームがあるか
        $vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'LabStore' }
        if (-not $vol) {
            # RAW ディスクを探す (未初期化)
            $raw = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Sort-Object Number | Select-Object -First 1
            if (-not $raw) { throw "L1 内に未初期化 (RAW) ディスクが見つかりません。ホットアドを確認してください。" }
            $out += "RAW disk #$($raw.Number) を初期化"
            Initialize-Disk -Number $raw.Number -PartitionStyle GPT
            # ドライブレターが空いていなければ解放を試みる
            $part = New-Partition -DiskNumber $raw.Number -UseMaximumSize -DriveLetter $Letter
            Format-Volume -DriveLetter $Letter -FileSystem NTFS -NewFileSystemLabel 'LabStore' -Confirm:$false | Out-Null
            $out += "ドライブ ${Letter}: を LabStore として初期化"
        } else {
            $out += "LabStore ボリュームは既存 ($($vol.DriveLetter):)"
            $Letter = $vol.DriveLetter
        }

        $base = "${Letter}:"
        foreach ($d in @("$base\images","$base\vms")) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null; $out += "作成: $d" }
        }

        # 既存 golden を OS ディスク(C:)からラボストアへ移動して C: を解放
        $oldImg = 'C:\NestedLab\images'
        if (Test-Path $oldImg) {
            Get-ChildItem $oldImg -Filter *.vhdx -ErrorAction SilentlyContinue | ForEach-Object {
                $dst = Join-Path "$base\images" $_.Name
                if (-not (Test-Path $dst)) {
                    $out += "golden を移動: $($_.FullName) -> $dst"
                    Move-Item -LiteralPath $_.FullName -Destination $dst -Force
                }
            }
            # 空になった旧フォルダは掃除 (C: 配下のラボ専用フォルダのみ)
            if (-not (Get-ChildItem $oldImg -ErrorAction SilentlyContinue)) {
                Remove-Item 'C:\NestedLab' -Recurse -Force -ErrorAction SilentlyContinue
                $out += "旧 C:\NestedLab を削除"
            }
        }

        # Hyper-V 既定の VM / VHD 配置先をラボストアへ
        Set-VMHost -VirtualMachinePath "$base\vms" -VirtualHardDiskPath "$base\vms"
        $out += "Set-VMHost: VM/VHD path -> $base\vms"

        # 容量レポート
        $v = Get-Volume -DriveLetter $Letter
        $out += ("LabStore: {0}: {1}GB free / {2}GB" -f $Letter, [math]::Round($v.SizeRemaining/1GB,1), [math]::Round($v.Size/1GB,1))
        $out
    } -ArgumentList $DriveLetter

    $result | ForEach-Object { Log $_ }
}
finally {
    if ($session) { Remove-PSSession $session }
}
Log "ラボストア構成 完了"
exit 0
