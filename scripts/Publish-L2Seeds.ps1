#Requires -Version 5.1
<#
.SYNOPSIS
  Linux L2 VM 用の cloud-init NoCloud シード (CIDATA) を生成し、L1 へ配送する。

.DESCRIPTION
  L2 Linux は LabNAT 上で DHCP が無いため、cloud-init で hostname / 静的IP / SSH 公開鍵を
  与える必要がある。本スクリプトは確定モデル(resolved.json)の Linux VM ごとに
  New-CloudInitSeed.ps1 でシード VHDX を作り (FAT32/CIDATA, ISOツール不要=原則①)、
  PowerShell Direct (VMBus) で L1 の L:\seeds へ配置する。

  l2_vm ロール(Linux 分岐)はこのシードを L:\seeds\<name>-seed.vhdx として添付する。
  冪等: 毎回シードを作り直し、L1 側の同名を置換する。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Model,
    [string]$VMName,                                 # L1 VM 名 (既定: model l1.name)
    [string]$SeedDir = "L:\seeds",                   # L1 内の配置先
    [string]$SshPubKeyPath,                          # 既定: build/ssh/id_ed25519.pub
    [string]$L1User = "Administrator",
    [string]$L1Password = "P@ssw0rd-Lab-Change!"
)
$ErrorActionPreference = "Stop"
function Log($m){ Write-Host "  [seeds] $m" -ForegroundColor DarkCyan }
if (-not $Model) { $Model = Join-Path $RepoRoot "build\resolved.json" }
if (-not $SshPubKeyPath) { $SshPubKeyPath = Join-Path $RepoRoot "build\ssh\id_ed25519.pub" }
if (-not (Test-Path $Model)) { throw "resolved model がありません: $Model" }
if (-not (Test-Path $SshPubKeyPath)) { throw "SSH 公開鍵がありません: $SshPubKeyPath (制御VM作成で生成されます)" }

# 注意: パラメータ $Model は [string]。PowerShell は変数名が大文字小文字を区別しないため
# $model に代入するとオブジェクトが文字列へ強制変換される。別名 $cfg を使う。
$cfg = Get-Content $Model -Raw | ConvertFrom-Json
if (-not $VMName) { $VMName = $cfg.l1.name }
$prefix = [int]($cfg.l1.nat.subnet -split '/')[1]
$pub = (Get-Content $SshPubKeyPath -Raw).Trim()

# Linux VM を抽出
$linux = @($cfg.vms | Where-Object { $_.os -match 'ubuntu|debian|linux|rocky|alma' })
if (-not $linux) { Log "Linux L2 はありません。何もしません。"; exit 0 }

# シードをローカル生成
$seedScript = Join-Path $RepoRoot "scripts\New-CloudInitSeed.ps1"
$localSeedDir = Join-Path $RepoRoot "build\seeds"
New-Item -ItemType Directory -Force -Path $localSeedDir | Out-Null
$made = @()
foreach ($vm in $linux) {
    $name = $vm.name
    $ip = $vm.nics[0].ip
    $gw = $vm.nics[0].gw
    $cidr = "$ip/$prefix"
    $seed = Join-Path $localSeedDir "$name-seed.vhdx"
    $locale = if ($vm.locale) { $vm.locale } else { 'en_US.UTF-8' }
    Log "シード生成: $name ($cidr gw=$gw locale=$locale)"
    & $seedScript -SeedPath $seed -Hostname $name -IPCidr $cidr -Gateway $gw -SshPubKey $pub -Locale $locale | Out-Null
    $made += [pscustomobject]@{ Name=$name; Local=$seed }
}

# L1 へ配送 (PowerShell Direct セッションで既存削除 → Copy-VMFile)
$cred = New-Object System.Management.Automation.PSCredential($L1User,(ConvertTo-SecureString $L1Password -AsPlainText -Force))
$session = New-PSSession -VMName $VMName -Credential $cred
try {
    Invoke-Command -Session $session -ScriptBlock { param($d) if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } } -ArgumentList $SeedDir
    foreach ($m in $made) {
        $dest = ($SeedDir.TrimEnd('\')) + '\' + (Split-Path $m.Local -Leaf)
        Invoke-Command -Session $session -ScriptBlock { param($p) if (Test-Path $p) { Remove-Item -LiteralPath $p -Force } } -ArgumentList $dest
        Log "配送: $($m.Name) -> $dest"
        Copy-VMFile -VMName $VMName -SourcePath $m.Local -DestinationPath $dest -FileSource Host -CreateFullPath
    }
} finally { Remove-PSSession $session }
Log "シード配送 完了 ($($made.Count) 件)"
exit 0
