#Requires -Version 5.1
<#
.SYNOPSIS
  制御ノード (Ansible 内蔵 Ubuntu VM) を L0 上に冪等に構築し、疎通を確立する。

.DESCRIPTION
  - CtrlNAT (Internal+NAT) ネットワークを確保 (静的 IP + 外部到達)
  - SSH 鍵をホスト側に用意 (無ければ生成)
  - Ubuntu cloud VHDX を複製し Gen2 VM を作成 (Secure Boot Off)
  - cloud-init シード (CIDATA) を投入して起動
  - -WaitReady で SSH 疎通と ansible 動作を検証

  冪等: VM があれば再作成しない。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Model,
    [string]$Name = "nested-lab-ctrl",
    [int]$Cpu = 2,
    [int]$MemoryGB = 6,   # Ansible/Kerberos ツールチェーン(pywinrm[kerberos]のビルド・playbook実行)で 4GB だと枯渇しやすい (KB/0011)
    [string]$Switch = "CtrlNAT",
    [string]$Subnet = "10.20.0.0/24",
    [string]$HostIp = "10.20.0.1",
    [string]$IPCidr = "10.20.0.10/24",
    [string]$AnsibleVersion = "2.17.5",
    [switch]$WaitReady,
    [int]$TimeoutSec = 600
)
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\HyperVLab.psm1.ps1")

function Log($m){ Write-Host "  [ctrl] $m" -ForegroundColor DarkCyan }
$ip = $IPCidr.Split('/')[0]

# --- ネットワーク ---
Ensure-NatNetwork -SwitchName $Switch -Subnet $Subnet -HostIp $HostIp | Out-Null
Log "ネットワーク $Switch ($Subnet, gw $HostIp) を確保"

# --- SSH 鍵 ---
$sshDir = Join-Path $RepoRoot "build\ssh"
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
$key = Join-Path $sshDir "id_ed25519"
$pub = "$key.pub"
if (-not (Test-Path $pub)) {
    Log "SSH 鍵を生成"
    # 空パスフレーズは "" (2文字) ではなく真の空文字。PowerShell では「" ""」と
    # 解釈される罠を避けるため、パラメータ配列で空文字を明示的に渡す。
    $ka = @('-t','ed25519','-N','','-f',$key,'-C','nestedlab-ctrl','-q')
    & ssh-keygen @ka
    if (-not (Test-Path $pub)) { throw "ssh-keygen に失敗しました (OpenSSH クライアントが必要)。" }
    # 生成した鍵が本当に空パスフレーズか自己検証 (回帰防止)
    & ssh-keygen -y -P '' -f $key | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "生成した SSH 鍵が空パスフレーズではありません。" }
}
$pubKey = (Get-Content $pub -Raw).Trim()

# --- Ubuntu VHDX 確保 ---
$ubuntu = Join-Path $RepoRoot "assets\ubuntu2404-cloudimg.vhdx"
if (-not (Test-Path $ubuntu)) {
    Log "Ubuntu イメージが無いため取得"
    & (Join-Path $RepoRoot "scripts\Get-UbuntuImage.ps1") -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "Ubuntu イメージ整備に失敗しました。" }
}

# --- VM 作成 (冪等) ---
if (-not (Get-VM -Name $Name -ErrorAction SilentlyContinue)) {
    # 自己完結構造: 制御 VM のディスクもリポジトリ配下 data/vms に置く
    $dataRoot = Get-LabDataRoot -RepoRoot $RepoRoot
    $dir = Join-Path (Join-Path $dataRoot "vms") $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $osDisk = Join-Path $dir "$Name-os.vhdx"
    if (-not (Test-Path $osDisk)) {
        Copy-Item $ubuntu $osDisk
        # Ubuntu cloud イメージの rootfs は ~3.5GB と小さく、pip(ansible/pywinrm) +
        # collection + 繰り返す scp 同期 + ~/.ansible/tmp で「No space left on device」になる。
        # 初回起動前にディスクを拡張しておけば cloud-init の growpart が rootfs を伸ばす。
        Resize-VHD -Path $osDisk -SizeBytes 32GB
    }

    # 制御 VM が L1 ルータ経由で L2 (LabNAT) へ到達するための静的ルート。
    $labSubnet = "10.10.0.0/24"
    if ($Model -and (Test-Path $Model)) {
        try { $labSubnet = (Get-Content $Model -Raw | ConvertFrom-Json).l1.nat.subnet } catch {}
    }
    $l2Route = "$labSubnet=10.20.0.20"   # 10.20.0.20 = L1 の CtrlNAT 側 IP (ルータ)

    $seed = Join-Path $dir "$Name-seed.vhdx"
    & (Join-Path $RepoRoot "scripts\New-CloudInitSeed.ps1") `
        -SeedPath $seed -Hostname $Name -IPCidr $IPCidr -Gateway $HostIp `
        -SshPubKey $pubKey -AnsibleVersion $AnsibleVersion -ExtraRoutes $l2Route

    New-VM -Name $Name -Generation 2 -MemoryStartupBytes ([int64]$MemoryGB*1GB) `
           -VHDPath $osDisk -SwitchName $Switch | Out-Null
    Add-VMHardDiskDrive -VMName $Name -Path $seed
    Set-VMProcessor -VMName $Name -Count $Cpu
    Set-VMFirmware -VMName $Name -EnableSecureBoot Off   # Linux Gen2 のため
    # 動的メモリの下限を明示する。既定 (Minimum 512MB) のままだとアイドル時にバルーンで
    # 512MB まで縮み、その状態で scp / ansible-playbook が走ると VM がスラッシュして
    # SSH 転送がスタックする (KB/0011)。下限 2GB / 上限=Startup で常に応答可能に保つ。
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
        -MinimumBytes 2GB -StartupBytes ([int64]$MemoryGB*1GB) -MaximumBytes ([int64]$MemoryGB*1GB)
    Log "VM '$Name' を作成 (Gen2, $Cpu vCPU, ${MemoryGB}GB[min2GB], SecureBoot Off)"
} else {
    Log "VM '$Name' は既に存在 (no-change)"
}

if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name; Log "起動しました" }

if (-not $WaitReady) { exit 0 }

# --- 疎通待ち + ansible 検証 ---
Log "SSH 疎通待ち (最大 ${TimeoutSec}s, $ip)..."
# 制御 VM を作り直すとホスト鍵が変わり、古い known_hosts と衝突して警告が出る。消しておく。
$knownHosts = Join-Path $env:TEMP 'nl_known'
if (Test-Path $knownHosts) { Remove-Item $knownHosts -Force -ErrorAction SilentlyContinue }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$sshOpts = @(
    "-i", $key,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=$env:TEMP\nl_known",
    "-o", "ConnectTimeout=5",
    "-o", "BatchMode=yes",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=3"
)

# ConnectTimeout only covers connection establishment. On Windows OpenSSH an ssh.exe process
# can remain alive after the remote command has completed, which would freeze this loop before
# the outer stopwatch gets another chance to evaluate TimeoutSec. Give every individual probe a
# hard 15-second process deadline and kill its process tree when exceeded (KB/0020).
function Invoke-SshReadinessProbe {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "ssh"
    $psi.UseShellExecute = $false
    # Do not redirect output here. On Windows OpenSSH, ReadToEnd() can wait forever for EOF
    # even after ssh.exe itself has exited. The remote test command's exit code is sufficient.
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    foreach ($arg in $sshOpts) { [void]$psi.ArgumentList.Add($arg) }
    [void]$psi.ArgumentList.Add("labadmin@$ip")
    [void]$psi.ArgumentList.Add("test -s /home/labadmin/ansible-ready.txt")

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    if (-not $process.WaitForExit(15000)) {
        $process.Kill($true)
        $process.WaitForExit()
        return 124
    }
    return $process.ExitCode
}

$ready = $false
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $probeExitCode = Invoke-SshReadinessProbe
    if ($probeExitCode -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 10
}
if (-not $ready) { throw "制御ノードの準備がタイムアウトしました (cloud-init/ansible 未完了の可能性)。" }
Log "SSH 疎通 OK / $out"

# ansible 動作確認 (localhost ping)
$ping = & ssh @sshOpts "labadmin@$ip" "ansible -i localhost, -c local -m ping all" 2>&1
Log "ansible ping 結果:"
$ping | ForEach-Object { Write-Host "    $_" }
if ($ping -match "SUCCESS|pong") { Log "制御ノード疎通・Ansible 動作を確認しました"; exit 0 }
throw "ansible ping が成功しませんでした。"
