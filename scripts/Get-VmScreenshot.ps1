#Requires -Version 5.1
<#
.SYNOPSIS
  Hyper-V VM のコンソール画面を PNG で取得する (デバッグ補助)。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$OutPath,
    [int]$Width = 800, [int]$Height = 600
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$ns = "root\virtualization\v2"
$vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
if (-not $vm) { throw "VM not found: $VMName" }
$settings = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData -Association Msvm_SettingsDefineState
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$res = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{
    TargetSystem = $settings; WidthPixels = [uint16]$Width; HeightPixels = [uint16]$Height }
if ($res.ReturnValue -ne 0 -or $res.ImageData.Length -eq 0) { throw "thumbnail failed rc=$($res.ReturnValue)" }
$bytes = $res.ImageData
$bmp = New-Object System.Drawing.Bitmap($Width, $Height)
for ($y=0; $y -lt $Height; $y++) {
    for ($x=0; $x -lt $Width; $x++) {
        $i = ($y*$Width + $x)*2
        if ($i+1 -lt $bytes.Length) {
            $px = [BitConverter]::ToUInt16($bytes, $i)
            $r = [int]((($px -shr 11) -band 0x1F)*255/31)
            $g = [int]((($px -shr 5) -band 0x3F)*255/63)
            $b = [int](($px -band 0x1F)*255/31)
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($r,$g,$b))
        }
    }
}
New-Item -ItemType Directory -Force -Path (Split-Path $OutPath) | Out-Null
$bmp.Save($OutPath)
"saved $OutPath"
