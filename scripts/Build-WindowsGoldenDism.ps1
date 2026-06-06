#Requires -Version 5.1
<#
.SYNOPSIS
  Windows 標準ツールのみで Windows Server golden VHDX を生成する (外部依存ゼロ)。

.DESCRIPTION
  Packer/oscdimg/ADK を使わず、Hyper-V + DISM 標準コマンドだけで完結する。原則① に最も忠実。
  手順:
    1. ISO をマウントし install.wim/esd から目的エディションのインデックスを特定
    2. 空の Gen2 VHDX を作成し、EFI/MSR/Windows パーティションを作成
    3. Expand-WindowsImage で Windows を直接展開 (無人インストール起動すら不要)
    4. bcdboot で UEFI ブートを構成
    5. Panther\unattend.xml を配置 (初回起動で OOBE 無人通過 + WinRM 有効化)
    6. VHDX を detach -> golden として確定配置

  冪等: golden VHDX があれば何もしない。
  注意: 展開した VHDX は「初回起動時に固有化される」状態。sysprep 済みイメージではなく
        unattend による specialize/oobe で各 VM 固有化する方式 (Nested ラボに十分)。

.PARAMETER Edition  install.wim のエディション名 (既定: Datacenter デスクトップ Evaluation)。
                    Datacenter は Standard の上位互換で、S2D (記憶域スペースダイレクト) を
                    使うには Datacenter が必須のため既定を Datacenter にしている。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$IsoDir,
    [string]$VhdxName = "win2025-golden-en-us.vhdx",
    [string]$IsoName,                                   # 言語別 ISO を明示指定する場合のファイル名
    [string]$AdminPassword = "P@ssw0rd-Lab-Change!",
    [string]$Edition = "Windows Server 2025 Datacenter Evaluation (デスクトップ エクスペリエンス)",
    [int]$DiskGB = 40
)
$ErrorActionPreference = "Stop"
$assets = Join-Path $RepoRoot "assets"
if (-not $IsoDir) { $IsoDir = Join-Path $assets "iso" }
$vhdx = Join-Path $assets $VhdxName
New-Item -ItemType Directory -Force -Path $assets | Out-Null
function Log($m){ Write-Host "  [win-dism] $m" -ForegroundColor DarkCyan }

if (Test-Path $vhdx) { Log "golden VHDX は既に存在 (no-change): $vhdx"; exit 0 }

# --- ISO 特定 ---
if ($IsoName) {
    # 言語別 ISO を明示指定 (bootstrap が事前に Get-WindowsIso で配置済みのはず)
    $iso = Get-Item (Join-Path $IsoDir $IsoName) -ErrorAction SilentlyContinue
    if (-not $iso) { Log "指定 ISO '$IsoName' が無いため自動ダウンロードします"; & (Join-Path $PSScriptRoot "Get-WindowsIso.ps1") -RepoRoot $RepoRoot -IsoDir $IsoDir -IsoName $IsoName; if ($LASTEXITCODE -ne 0) { exit 3 }; $iso = Get-Item (Join-Path $IsoDir $IsoName) -ErrorAction SilentlyContinue }
    if (-not $iso) { exit 3 }
} else {
    $iso = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '(?i)SERVER_EVAL|server.*2025|2025.*server|_SERVER_' } | Select-Object -First 1
    if (-not $iso) { $iso = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $iso) {
        Log "ISO が無いため自動ダウンロードします (en-us)"
        & (Join-Path $PSScriptRoot "Get-WindowsIso.ps1") -RepoRoot $RepoRoot -IsoDir $IsoDir
        if ($LASTEXITCODE -ne 0) { exit 3 }
        $iso = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '(?i)SERVER_EVAL|server.*2025|2025.*server|_SERVER_' } | Select-Object -First 1
        if (-not $iso) { $iso = Get-ChildItem -Path $IsoDir -Filter *.iso -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not $iso) { exit 3 }
    }
}
Log "ISO: $($iso.Name)"

$mountedIso = $null; $mountedVhdx = $false
try {
    # --- ISO マウント ---
    $img = Mount-DiskImage -ImagePath $iso.FullName -PassThru
    $mountedIso = $iso.FullName
    $isoVol = ($img | Get-Volume).DriveLetter
    $wim = @("$isoVol`:\sources\install.wim","$isoVol`:\sources\install.esd") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $wim) { throw "install.wim/esd が見つかりません。" }
    Log "WIM: $wim"

    # エディション選択は言語非依存に。指定名で一致しなければ
    # Datacenter + Evaluation + (Desktop Experience/デスクトップ) をパターンで選ぶ
    # (英語 ISO/日本語 ISO のどちらでも golden を作れるようにする)。
    # Datacenter は Standard 上位互換で S2D に必須。
    $imgs = Get-WindowsImage -ImagePath $wim
    $sel = $imgs | Where-Object { $_.ImageName -eq $Edition } | Select-Object -First 1
    if (-not $sel) { $sel = $imgs | Where-Object { $_.ImageName -match '(?i)datacenter' -and $_.ImageName -match '(?i)eval' -and $_.ImageName -match '(?i)desktop|デスクトップ' } | Select-Object -First 1 }
    if (-not $sel) { $sel = $imgs | Where-Object { $_.ImageName -match '(?i)datacenter' -and $_.ImageName -match '(?i)eval' } | Select-Object -First 1 }
    # 最後の保険: Datacenter が無ければ Standard デスクトップ (S2D は不可だが他は動く)
    if (-not $sel) { $sel = $imgs | Where-Object { $_.ImageName -match '(?i)standard' -and $_.ImageName -match '(?i)eval' -and $_.ImageName -match '(?i)desktop|デスクトップ' } | Select-Object -First 1 }
    if (-not $sel) {
        $avail = ($imgs | ForEach-Object { $_.ImageName }) -join " | "
        throw "Datacenter/Standard Evaluation エディションが見つかりません。利用可能: $avail"
    }
    $idx = $sel.ImageIndex
    Log "エディション '$($sel.ImageName)' = index $idx"

    # --- VHDX 作成 + パーティション (拡張子は .vhdx 必須) ---
    $tmpVhdx = Join-Path $assets "building-$VhdxName"
    if (Test-Path $tmpVhdx) { Remove-Item $tmpVhdx -Force }
    $disk = New-VHD -Path $tmpVhdx -SizeBytes ([int64]$DiskGB*1GB) -Dynamic | Mount-VHD -Passthru | Get-Disk
    $mountedVhdx = $true
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false | Out-Null

    # EFI (FAT32 260MB) + MSR(16MB) + Windows(残り)
    $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
    $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false | Out-Null
    $efi | Set-Partition -NewDriveLetter S
    New-Partition -DiskNumber $disk.Number -Size 16MB -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" | Out-Null
    $win = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}"
    $win | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
    $win | Set-Partition -NewDriveLetter W
    Log "パーティション作成: S:(EFI) W:(Windows)"

    # --- Windows 展開 ---
    Log "Windows を展開中 (Expand-WindowsImage)... 数分かかります"
    Expand-WindowsImage -ImagePath $wim -Index $idx -ApplyPath "W:\" | Out-Null

    # --- UEFI ブート構成 ---
    Log "bcdboot で UEFI ブート構成"
    & "W:\Windows\System32\bcdboot.exe" W:\Windows /s S: /f UEFI
    if ($LASTEXITCODE -ne 0) { throw "bcdboot に失敗しました。" }

    # --- unattend 配置 (OOBE 無人 + WinRM) ---
    $unattendSrc = Join-Path $RepoRoot "packer\windows-server\unattend-golden.xml"
    $content = (Get-Content $unattendSrc -Raw) -replace "\{\{ADMIN_PASSWORD\}\}", $AdminPassword
    New-Item -ItemType Directory -Force -Path "W:\Windows\Panther" | Out-Null
    [System.IO.File]::WriteAllText("W:\Windows\Panther\unattend.xml", $content, (New-Object Text.UTF8Encoding($false)))
    Log "unattend.xml を配置"

    # --- detach -> 確定 ---
    Dismount-VHD -Path $tmpVhdx; $mountedVhdx = $false
    Dismount-DiskImage -ImagePath $mountedIso | Out-Null; $mountedIso = $null
    Move-Item -Path $tmpVhdx -Destination $vhdx -Force
    Log "完了: $vhdx ($([math]::Round((Get-Item $vhdx).Length/1GB,2))GB)"
}
catch {
    Log "失敗: $($_.Exception.Message)"
    if ($mountedVhdx) { Dismount-VHD -Path $tmpVhdx -ErrorAction SilentlyContinue }
    if ($mountedIso)  { Dismount-DiskImage -ImagePath $mountedIso -ErrorAction SilentlyContinue | Out-Null }
    if (Test-Path "$assets\building-$VhdxName") { Remove-Item "$assets\building-$VhdxName" -Force -ErrorAction SilentlyContinue }
    exit 1
}
exit 0
