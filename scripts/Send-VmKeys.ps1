#Requires -Version 5.1
<#
.SYNOPSIS
  Type into a Hyper-V VM (L1, or L2 through its L1) with the virtual keyboard. Nothing is installed in the guest.

.DESCRIPTION
  Drives Msvm_Keyboard, the same device the Hyper-V console uses, so it works on the lock screen, before the
  network is up and with no agent in the guest. Steps run in order:

    ctrl-alt-del        secure attention sequence (sign-in screen)
    text:<ascii>        type a string (TypeText; US layout, see KB/0031 for guests with a Japanese layout)
    key:<name>          one key or a chord: Enter, Tab, Esc, Win, Win+R, Ctrl+Shift+Esc, Alt+F4, F5, Up ...
    sleep:<ms>          wait

.EXAMPLE
  .\scripts\Send-VmKeys.ps1 -VMName srv01 -L1 nested-lab-01 -Steps 'ctrl-alt-del','sleep:1500','text:P@ssw0rd','key:Enter'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string[]]$Steps,
    [string]$L1,
    [int]$KeyDelayMs = 80,
    [string]$L1User = "Administrator",
    [string]$L1Password = "P@ssw0rd-Lab-Change!"
)
$ErrorActionPreference = "Stop"

$send = {
    param($VMName, $Steps, $KeyDelayMs)
    $ErrorActionPreference = "Stop"
    $vk = @{
        Enter = 0x0D; Tab = 0x09; Esc = 0x1B; Space = 0x20; Backspace = 0x08; Delete = 0x2E
        Up = 0x26; Down = 0x28; Left = 0x25; Right = 0x27; Home = 0x24; End = 0x23; PageUp = 0x21; PageDown = 0x22
        Shift = 0x10; Ctrl = 0x11; Alt = 0x12; Win = 0x5B; Apps = 0x5D
    }
    1..12 | ForEach-Object { $vk["F$_"] = 0x6F + $_ }
    function Get-Vk([string]$name) {
        if ($vk.ContainsKey($name)) { return [uint32]$vk[$name] }
        if ($name.Length -eq 1 -and $name -match '[A-Za-z0-9]') { return [uint32][char]$name.ToUpper() }
        throw "unknown key: $name"
    }
    $vm = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
    if (-not $vm) { throw "VM not found: $VMName" }
    $kb = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard
    function Invoke-Kb([string]$method, [hashtable]$arguments = @{}) {
        $r = Invoke-CimMethod -InputObject $kb -MethodName $method -Arguments $arguments
        if ($r.ReturnValue -ne 0) { throw "$method failed rc=$($r.ReturnValue)" }
    }
    foreach ($step in $Steps) {
        $kind, $value = $step -split ':', 2
        switch ($kind) {
            'ctrl-alt-del' { Invoke-Kb TypeCtrlAltDel }
            'text' { Invoke-Kb TypeText @{ asciiText = $value } }
            'sleep' { Start-Sleep -Milliseconds ([int]$value) }
            'key' {
                $names = $value -split '\+'
                $mods = @($names | Select-Object -SkipLast 1 | ForEach-Object { Get-Vk $_ })
                foreach ($m in $mods) { Invoke-Kb PressKey @{ keyCode = $m } }
                try { Invoke-Kb TypeKey @{ keyCode = (Get-Vk $names[-1]) } }
                finally { [array]::Reverse($mods); foreach ($m in $mods) { Invoke-Kb ReleaseKey @{ keyCode = $m } } }
            }
            default { throw "unknown step: $step (ctrl-alt-del / text:... / key:... / sleep:ms)" }
        }
        Start-Sleep -Milliseconds $KeyDelayMs
    }
    "sent $($Steps.Count) steps to $VMName"
}

$argv = @($VMName, $Steps, $KeyDelayMs)
if ($L1) {
    $cred = New-Object System.Management.Automation.PSCredential($L1User,
        (ConvertTo-SecureString $L1Password -AsPlainText -Force))
    Invoke-Command -VMName $L1 -Credential $cred -ScriptBlock $send -ArgumentList $argv
} else {
    & $send @argv
}
