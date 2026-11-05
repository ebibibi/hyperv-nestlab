#Requires -Version 7
<#
.SYNOPSIS
  Run bootstrap.ps1 detached from the current session, with a result you can poll.

.DESCRIPTION
  Starting bootstrap from SSH or automation has three known traps (KB/0027): ssh waits on an
  inherited stdin forever, the SSH session kills its child processes, and a scheduled task cannot
  see a per-user Python. This script handles all three: it registers a scheduled task as the
  current user, passes the Python folder explicitly, and gives bootstrap an empty stdin.

  Poll build\bootstrap.status. It always ends with EXITCODE=<n> and DONE, including on failure,
  because bootstrap runs as a child process. Output is in build\bootstrap.log.

.PARAMETER L1        L1 declaration, relative to the repository.
.PARAMETER L2        L2 declaration, relative to the repository.
.PARAMETER Rebuild   Run teardown.ps1 -Force first. It removes the L1 and control VM of the current model.
.PARAMETER DryRun    Pass -DryRun to bootstrap.

.EXAMPLE
  pwsh -File scripts\Start-LabBootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\entra-hybrid-join.yml -Rebuild
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$L1,
    [Parameter(Mandatory)][string]$L2,
    [switch]$Rebuild,
    [switch]$DryRun,
    [string]$TaskName = "nestlab-bootstrap",
    # Internal: set by the scheduled task.
    [switch]$Run,
    [string]$PythonDir
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root "build"
New-Item -ItemType Directory -Force -Path $build | Out-Null
$status = Join-Path $build "bootstrap.status"
$pwsh = (Get-Process -Id $PID).Path

if (-not $Run) {
    $running = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($running -and $running.State -eq "Running") { throw "Task '$TaskName' is already running." }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw "Python was not found on PATH. bootstrap needs it for tools/resolve.py." }

    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Run",
        "-L1", "`"$L1`"", "-L2", "`"$L2`"", "-PythonDir", "`"$(Split-Path -Parent $python.Source)`""
    )
    if ($Rebuild) { $arguments += "-Rebuild" }
    if ($DryRun) { $arguments += "-DryRun" }

    $action = New-ScheduledTaskAction -Execute $pwsh -Argument ($arguments -join " ") -WorkingDirectory $root
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 12) -AllowStartIfOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Set-Content -Path $status -Value "QUEUED $(Get-Date -Format o)" -Encoding UTF8
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Started task '$TaskName'. Poll $status and read $(Join-Path $build 'bootstrap.log')."
    exit 0
}

function Write-Status([string]$Message) { Add-Content -Path $status -Value $Message -Encoding UTF8 }

$exitCode = 1
try {
    Set-Content -Path $status -Value "START $(Get-Date -Format o)" -Encoding UTF8
    if ($PythonDir) { $env:PATH = "$PythonDir;$PythonDir\Scripts;$env:PATH" }
    $stdin = Join-Path $build "empty-stdin.txt"
    Set-Content -Path $stdin -Value "" -NoNewline

    function Invoke-Child([string]$Name, [string[]]$ChildArguments) {
        # Real file handles capture native child output too, which PowerShell redirection does not.
        $process = Start-Process -FilePath $pwsh -WorkingDirectory $root -NoNewWindow -PassThru `
            -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File") + $ChildArguments) `
            -RedirectStandardInput $stdin `
            -RedirectStandardOutput (Join-Path $build "$Name.log") `
            -RedirectStandardError (Join-Path $build "$Name.err")
        $process.WaitForExit()
        return $process.ExitCode
    }

    if ($Rebuild) {
        $teardown = Invoke-Child "teardown" @((Join-Path $root "teardown.ps1"), "-Force")
        Write-Status "TEARDOWN=$teardown $(Get-Date -Format o)"
        if ($teardown -ne 0) { $exitCode = $teardown; return }
    }

    $bootstrapArguments = @((Join-Path $root "bootstrap.ps1"), "-L1", $L1, "-L2", $L2)
    if ($DryRun) { $bootstrapArguments += "-DryRun" }
    $exitCode = Invoke-Child "bootstrap" $bootstrapArguments
}
catch {
    Write-Status "ERROR $($_.Exception.Message)"
}
finally {
    Write-Status "EXITCODE=$exitCode"
    Write-Status "DONE $(Get-Date -Format o)"
}
exit $exitCode
