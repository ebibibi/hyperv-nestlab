#Requires -Version 5.1
<#
.SYNOPSIS
  Capture the console screen of a Hyper-V VM (L1, or L2 through its L1) as PNG. Nothing is installed in the guest.

.DESCRIPTION
  Uses the Hyper-V WMI method Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage, which returns
  the current console frame as RGB565. It works before sign-in, without network access to the guest and with
  no agent inside it, so it can record verification evidence or explainer footage of any lab VM.

  - L2 VMs: pass -L1 <nested host>. The capture runs inside the L1 over PowerShell Direct and only the PNG bytes
    come back to L0.
  - Resolution: by default the guest's current resolution (Msvm_VideoHead), so the image is not rescaled.
  - A guest whose display went to sleep returns an all-black frame. -Wake taps Shift on the virtual keyboard first.
  - -Count > 1 captures a burst into the directory -OutPath (frame_00001.png ... plus frames.csv with the
    offset of each frame in milliseconds). The frame rate is limited by the WMI call (see KB/0031).

.EXAMPLE
  .\scripts\Get-VmScreenshot.ps1 -VMName srv01 -L1 nested-lab-01 -Wake -OutPath D:\shots\srv01.png
.EXAMPLE
  .\scripts\Get-VmScreenshot.ps1 -VMName nested-lab-01 -OutPath D:\shots\l1.png
.EXAMPLE
  .\scripts\Get-VmScreenshot.ps1 -VMName srv01 -L1 nested-lab-01 -Count 20 -IntervalMs 250 -OutPath D:\shots\burst
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$OutPath,
    [string]$L1,                                 # set when VMName is an L2 inside this L1
    [int]$Width = 0, [int]$Height = 0,           # 0 = guest's current resolution
    [switch]$Wake,
    [int]$Count = 1,
    [int]$IntervalMs = 500,
    [string]$L1User = "Administrator",
    [string]$L1Password = "P@ssw0rd-Lab-Change!"
)
$ErrorActionPreference = "Stop"

# Runs where the VM lives (L0 for an L1, the L1 for an L2). Returns one object per frame with PNG bytes.
$capture = {
    param($VMName, $Width, $Height, $Wake, $Count, $IntervalMs)
    $ErrorActionPreference = "Stop"
    Add-Type -AssemblyName System.Drawing
    $ns = "root\virtualization\v2"
    $vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
    if (-not $vm) { throw "VM not found: $VMName" }
    if ($vm.EnabledState -ne 2) { throw "VM is not running: $VMName" }
    if ($Wake) {
        $kb = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard
        Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = [uint32]0x10 } | Out-Null
        Start-Sleep -Seconds 2
    }
    if ($Width -le 0 -or $Height -le 0) {
        $head = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VideoHead |
            Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
        $Width = if ($head) { [int]$head.CurrentHorizontalResolution } else { 1024 }
        $Height = if ($head) { [int]$head.CurrentVerticalResolution } else { 768 }
    }
    $settings = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData `
        -Association Msvm_SettingsDefineState
    $svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($n = 0; $n -lt $Count; $n++) {
        $due = $n * $IntervalMs
        $wait = $due - $sw.ElapsedMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
        $at = $sw.ElapsedMilliseconds
        $res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
            TargetSystem = $settings; WidthPixels = [uint16]$Width; HeightPixels = [uint16]$Height }
        if ($res.ReturnValue -ne 0 -or -not $res.ImageData) { throw "thumbnail failed rc=$($res.ReturnValue)" }
        # RGB565 rows are packed (Width*2 bytes). Copy them into the bitmap row by row because the bitmap
        # stride is padded to 4 bytes. SetPixel per pixel took minutes for a 1080p frame.
        $bytes = [byte[]]$res.ImageData
        $bmp = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
        $rect = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
        try {
            for ($y = 0; $y -lt $Height; $y++) {
                $dst = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
                [Runtime.InteropServices.Marshal]::Copy($bytes, $y * $Width * 2, $dst, $Width * 2)
            }
        } finally { $bmp.UnlockBits($data) }
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        [pscustomobject]@{ Index = $n + 1; OffsetMs = $at; Width = $Width; Height = $Height; Png = $ms.ToArray() }
    }
}

$argv = @($VMName, $Width, $Height, [bool]$Wake, $Count, $IntervalMs)
if ($L1) {
    $cred = New-Object System.Management.Automation.PSCredential($L1User,
        (ConvertTo-SecureString $L1Password -AsPlainText -Force))
    $frames = Invoke-Command -VMName $L1 -Credential $cred -ScriptBlock $capture -ArgumentList $argv
} else {
    $frames = & $capture @argv
}

if ($Count -eq 1) {
    $dir = Split-Path -Parent $OutPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllBytes($OutPath, [byte[]]$frames[0].Png)
    "saved $OutPath ($($frames[0].Width)x$($frames[0].Height))"
} else {
    New-Item -ItemType Directory -Force -Path $OutPath | Out-Null
    $rows = foreach ($f in $frames) {
        [IO.File]::WriteAllBytes((Join-Path $OutPath ("frame_{0:D5}.png" -f $f.Index)), [byte[]]$f.Png)
        "{0},{1}" -f $f.Index, $f.OffsetMs
    }
    Set-Content -Path (Join-Path $OutPath "frames.csv") -Value (@("index,offset_ms") + $rows) -Encoding UTF8
    "saved $($frames.Count) frames to $OutPath ($($frames[0].Width)x$($frames[0].Height))"
}
