#Requires -Version 5.1
<#
.SYNOPSIS
  Configure the control VM for Kerberos-authenticated WinRM to domain-joined L2 VMs.

.DESCRIPTION
  Runs only when the resolved model declares a domain. Pushes the resolved model and
  Setup-ControlKerberos.sh to the control VM and runs it as root (sudo): it writes
  /etc/krb5.conf, a deterministic /etc/hosts block for the domain L2 FQDNs, installs the
  krb5 client + build deps, and the pywinrm[kerberos] extra.

  Wiring: call this after the AD forest is up and before configure_l2.yml. The dynamic
  inventory (resolved_inventory.py) then connects domain members by FQDN with the
  kerberos transport, and Ansible auto-kinit's with the domain-admin UPN + password.
  See KB/0019.

.EXAMPLE
  Ensure-ControlKerberos.ps1 -RepoRoot D:\hyperv-nestlab -Model D:\hyperv-nestlab\build\resolved.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Model,
    [string]$Ip = "10.20.0.10",
    [string]$User = "labadmin"
)
$ErrorActionPreference = "Stop"
function Log($m){ Write-Host "  [krb] $m" -ForegroundColor DarkCyan }

$model = Get-Content $Model -Raw | ConvertFrom-Json
if (-not $model.domain) { Log "ドメイン無し → Kerberos 設定はスキップ"; exit 0 }

$runner = Join-Path $RepoRoot "scripts\ctrl\Run-OnControl.ps1"
$setup  = Join-Path $RepoRoot "control-node\Setup-ControlKerberos.sh"
if (-not (Test-Path $setup)) { throw "Setup-ControlKerberos.sh が見つかりません: $setup" }

Log "制御 VM へ Setup-ControlKerberos.sh と確定モデルを同期"
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Command "mkdir -p ~/nestedlab/build"
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Push @("$setup::/home/$User/nestedlab/Setup-ControlKerberos.sh")
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Push @("$Model::/home/$User/nestedlab/build/resolved.json")

# clone 由来の CRLF が混ざると bash が壊れるため、実行前に CR を除去する (KB/0001 と同方針)。
$cmd = "sed -i 's/\r`$//' ~/nestedlab/Setup-ControlKerberos.sh; sudo bash ~/nestedlab/Setup-ControlKerberos.sh ~/nestedlab/build/resolved.json"
Log "制御 VM 上で Kerberos 設定 (krb5.conf / hosts / krb5-user / pywinrm[kerberos]) を適用"
& $runner -RepoRoot $RepoRoot -Ip $Ip -User $User -Command $cmd
if ($LASTEXITCODE -ne 0) { throw "制御 VM の Kerberos 設定に失敗しました。" }
Log "完了"
exit 0
