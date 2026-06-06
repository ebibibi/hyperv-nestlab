#Requires -Version 5.1
<#
.SYNOPSIS
  cloud-init NoCloud のシードディスク (FAT32 ラベル CIDATA の VHDX) を生成する。

.DESCRIPTION
  ISO 作成ツール (oscdimg/mkisofs) を使わず、Hyper-V 標準 cmdlet だけで
  vfat シードを作る (原則①)。user-data / meta-data / network-config を書き込む。
  cloud-init はラベル "CIDATA" の vfat を NoCloud データソースとして読む。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SeedPath,        # 出力 VHDX
    [Parameter(Mandatory)][string]$Hostname,
    [Parameter(Mandatory)][string]$IPCidr,          # e.g. 10.20.0.10/24
    [Parameter(Mandatory)][string]$Gateway,
    [string[]]$Dns = @("1.1.1.1","8.8.8.8"),
    [Parameter(Mandatory)][string]$SshPubKey,
    [string]$AdminUser = "labadmin",
    [string]$AnsibleVersion = "2.17.5",
    [string]$Locale = "en_US.UTF-8"
)
$ErrorActionPreference = "Stop"

$userData = @"
#cloud-config
hostname: $Hostname
preserve_hostname: false
locale: $Locale
users:
  - name: $AdminUser
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - $SshPubKey
ssh_pwauth: false
package_update: true
packages:
  - python3
  - python3-pip
  - python3-venv
runcmd:
  - [ bash, -lc, "pip3 install --break-system-packages 'ansible-core==$AnsibleVersion' 'pywinrm==0.4.3' || (apt-get update && apt-get install -y ansible python3-winrm)" ]
  - [ bash, -lc, "ansible --version | head -1 > /home/$AdminUser/ansible-ready.txt 2>&1; chown $AdminUser`:$AdminUser /home/$AdminUser/ansible-ready.txt" ]
  - [ bash, -lc, "touch /run/cloud-ansible-ready" ]
final_message: "cloud-init done: control node ready"
"@

$metaData = @"
instance-id: $Hostname-001
local-hostname: $Hostname
"@

$netConfig = @"
version: 2
ethernets:
  eth0:
    match:
      name: "e*"
    dhcp4: false
    addresses:
      - $IPCidr
    routes:
      - to: default
        via: $Gateway
    nameservers:
      addresses: [$($Dns -join ', ')]
"@

# --- VHDX を作成 / フォーマット / 書き込み ---
if (Test-Path $SeedPath) { Remove-Item $SeedPath -Force }
New-Item -ItemType Directory -Force -Path (Split-Path $SeedPath) | Out-Null

$vhd = New-VHD -Path $SeedPath -SizeBytes 64MB -Dynamic
$disk = Mount-VHD -Path $SeedPath -Passthru | Get-Disk
try {
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction SilentlyContinue | Out-Null
    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -DriveLetter $part.DriveLetter -FileSystem FAT32 -NewFileSystemLabel "CIDATA" -Confirm:$false | Out-Null
    $root = "$($part.DriveLetter):\"
    $enc = New-Object System.Text.UTF8Encoding($false)   # BOM なし (cloud-init 対策)
    [System.IO.File]::WriteAllText((Join-Path $root "user-data"),      ($userData -replace "`r`n","`n"), $enc)
    [System.IO.File]::WriteAllText((Join-Path $root "meta-data"),      ($metaData -replace "`r`n","`n"), $enc)
    [System.IO.File]::WriteAllText((Join-Path $root "network-config"), ($netConfig -replace "`r`n","`n"), $enc)
}
finally {
    Dismount-VHD -Path $SeedPath
}
Write-Host "  [seed] 生成完了: $SeedPath (CIDATA)" -ForegroundColor DarkCyan
