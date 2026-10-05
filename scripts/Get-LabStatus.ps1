#Requires -Version 5.1
<#
.SYNOPSIS
  Print the current lab state as one JSON document (read-only).

.DESCRIPTION
  For front ends and automation that must not parse console text. Combines:
    - the declared model (build/resolved.json written by bootstrap.ps1), and
    - the live state of the control VM and the L1 host (Get-VM on L0), and
    - with -IncludeL2, the live state of every L2 inside the L1, queried over PowerShell Direct
      with an explicit credential (without -Credential PowerShell Direct hangs silently, KB/0016).

  Nothing is started, stopped or changed. When nothing has been built yet the document reports
  "built": false instead of failing. Problems that do not stop the report (L1 unreachable, timeout)
  are listed in "errors".

.EXAMPLE
  pwsh -NoProfile -File .\scripts\Get-LabStatus.ps1
.EXAMPLE
  pwsh -NoProfile -File .\scripts\Get-LabStatus.ps1 -IncludeL2 -L2TimeoutSec 30
#>
[CmdletBinding()]
param(
    [string]$ModelPath,
    [string]$ControlNodeName = "nested-lab-ctrl",
    [switch]$IncludeL2,
    [int]$L2TimeoutSec = 60,
    [string]$L1User = "Administrator",
    [string]$L1Password = "P@ssw0rd-Lab-Change!"
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ModelPath) { $ModelPath = Join-Path $RepoRoot "build\resolved.json" }

$errors = New-Object System.Collections.Generic.List[string]

function ConvertTo-VmEntry {
    param([string]$Layer, [string]$Name, $Vm)
    if (-not $Vm) {
        return [ordered]@{ layer = $Layer; name = $Name; exists = $false; state = "Missing" }
    }
    [ordered]@{
        layer      = $Layer
        name       = $Name
        exists     = $true
        state      = [string]$Vm.State
        cpu        = [int]$Vm.ProcessorCount
        memory_gb  = [math]::Round(([double]$Vm.MemoryStartup) / 1GB, 1)
        uptime_sec = [int][math]::Floor(([TimeSpan]$Vm.Uptime).TotalSeconds)
    }
}

function Get-ModelVmIp {
    param($Spec)
    if ($Spec.ip) { return [string]$Spec.ip }
    $nic = @($Spec.nics) | Where-Object { $_ -and $_.ip } | Select-Object -First 1
    if ($nic) { return [string]$nic.ip }
    return $null
}

# ---- declared model ----
$model = $null
if (Test-Path $ModelPath) {
    try { $model = Get-Content $ModelPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $errors.Add("resolved.json を読めません: $($_.Exception.Message)") }
}
$l1Name = if ($model) { [string]$model.l1.name } else { $null }
$l2Specs = if ($model) { @($model.vms) } else { @() }

# ---- live state on L0 ----
$hyperv = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
if (-not $hyperv) { $errors.Add("Hyper-V の PowerShell モジュールがありません (Get-VM が使えない)") }

function Get-L0Vm { param([string]$Name)
    if (-not $hyperv -or -not $Name) { return $null }
    Get-VM -Name $Name -ErrorAction SilentlyContinue
}

$vms = New-Object System.Collections.Generic.List[object]
$vms.Add((ConvertTo-VmEntry -Layer "control" -Name $ControlNodeName -Vm (Get-L0Vm $ControlNodeName)))
$l1Vm = Get-L0Vm $l1Name
if ($l1Name) { $vms.Add((ConvertTo-VmEntry -Layer "l1" -Name $l1Name -Vm $l1Vm)) }

# ---- L2 (inside the L1) ----
$l2Live = @{}
$l2Queried = $false
if ($IncludeL2 -and $l1Vm -and $l1Vm.State -eq "Running" -and $l2Specs.Count -gt 0) {
    $names = @($l2Specs | ForEach-Object { [string]$_.name })
    $job = Start-Job -ArgumentList $l1Name, $L1User, $L1Password, $names -ScriptBlock {
        param($L1, $User, $Password, $Names)
        $sec = ConvertTo-SecureString $Password -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
        Invoke-Command -VMName $L1 -Credential $cred -ArgumentList (, $Names) -ScriptBlock {
            param($Names)
            # Every VM in the L1, including ones added outside the declared model
            foreach ($v in @(Get-VM)) {
                [pscustomobject]@{
                    name = $v.Name; exists = $true; state = [string]$v.State
                    cpu = [int]$v.ProcessorCount
                    memory_gb = [math]::Round(([double]$v.MemoryStartup) / 1GB, 1)
                    uptime_sec = [int][math]::Floor($v.Uptime.TotalSeconds)
                }
            }
            foreach ($n in $Names) {
                if (-not (Get-VM -Name $n -ErrorAction SilentlyContinue)) {
                    [pscustomobject]@{ name = $n; exists = $false; state = "Missing" }
                }
            }
        }
    }
    if (Wait-Job $job -Timeout $L2TimeoutSec) {
        try {
            foreach ($r in @(Receive-Job $job -ErrorAction Stop)) { $l2Live[[string]$r.name] = $r }
            $l2Queried = $true
        } catch { $errors.Add("L2 の状態を取得できません (L1 への PowerShell Direct): $($_.Exception.Message)") }
    } else {
        $errors.Add("L2 の状態取得が ${L2TimeoutSec} 秒でタイムアウトしました (L1: $l1Name)")
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
} elseif ($IncludeL2 -and $l2Specs.Count -gt 0) {
    $errors.Add("L1 が起動していないため L2 の状態は取得していません")
}

foreach ($spec in $l2Specs) {
    $name = [string]$spec.name
    $entry = [ordered]@{ layer = "l2"; name = $name; managed = $true; os = [string]$spec.os; ip = (Get-ModelVmIp $spec) }
    $live = $l2Live[$name]
    if ($live) {
        foreach ($k in "exists", "state", "cpu", "memory_gb", "uptime_sec") {
            if ($null -ne $live.$k) { $entry[$k] = $live.$k }
        }
    } else {
        $entry["exists"] = $null      # unknown: not queried or L1 unreachable
        $entry["state"] = "Unknown"
    }
    $vms.Add($entry)
}

# L2 VMs that exist in the L1 but are not part of the declared model (added by hand or by other tools)
$declared = @($l2Specs | ForEach-Object { [string]$_.name })
foreach ($name in @($l2Live.Keys | Sort-Object)) {
    if ($declared -contains $name) { continue }
    $live = $l2Live[$name]
    $entry = [ordered]@{ layer = "l2"; name = $name; managed = $false; os = $null; ip = $null }
    foreach ($k in "exists", "state", "cpu", "memory_gb", "uptime_sec") { $entry[$k] = $live.$k }
    $vms.Add($entry)
}

$modelInfo = $null
if ($model) {
    $domainFqdn = if ($model.domain) { [string]$model.domain.fqdn } else { $null }
    $modelInfo = [ordered]@{
        l1     = $l1Name
        domain = $domainFqdn
        l2     = @($l2Specs | ForEach-Object { [string]$_.name })
    }
}

$doc = [ordered]@{
    schema       = 1
    generated_at = (Get-Date).ToString("o")
    host         = [ordered]@{ name = [Environment]::MachineName; hyperv = $hyperv }
    built        = [bool]$model
    l2_queried   = $l2Queried
    model        = $modelInfo
    vms          = $vms.ToArray()
    errors       = $errors.ToArray()
}
$doc | ConvertTo-Json -Depth 6
