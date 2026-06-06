#Requires -Version 5.1
<#
.SYNOPSIS
  制御 VM へファイル/ディレクトリを scp 同期し、リモートでコマンドを実行する小さな配管。

.DESCRIPTION
  SSH のクォート地獄を避けるため、実行物は常に「ローカルのファイルを scp -> リモートで実行」する。
  Phase 2 以降、ホスト側から制御 VM の Ansible を駆動する共通土台。

.PARAMETER Push
  "localPath::remotePath" の配列。ファイル/ディレクトリを制御 VM へ転送する。

.PARAMETER Command
  制御 VM 上で実行する bash コマンド (単一文字列)。

.EXAMPLE
  Run-OnControl -Push @("scripts\ctrl\verify-winrm-client.sh::/tmp/v.sh") -Command "bash /tmp/v.sh"
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$Ip = "10.20.0.10",
    [string]$User = "labadmin",
    [string[]]$Push = @(),
    [string]$Command,
    [int]$ConnectTimeout = 8
)
$ErrorActionPreference = "Stop"
$key = Join-Path $RepoRoot "build\ssh\id_ed25519"
if (-not (Test-Path $key)) { throw "SSH 鍵が見つかりません: $key (先に制御ノードを構築してください)" }

$sshOpts = @("-i", $key,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=$env:TEMP\nl_known_ctrl",
    "-o", "ConnectTimeout=$ConnectTimeout",
    # 確立後に転送が固まった場合 (例: 制御 VM のメモリ枯渇でスラッシュ) 無限待ちになるのを防ぐ。
    # 15s ごとに生存確認し、8 回連続無応答 (=120s) で切断して scp/ssh を非ゼロ終了させる。
    # こうすると Invoke-Ansible 側の throw が発火し、ハングではなく fail-fast になる (KB/0011)。
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=8",
    "-o", "BatchMode=yes")

foreach ($pair in $Push) {
    $parts = $pair -split "::", 2
    if ($parts.Count -ne 2) { throw "Push 形式エラー (localPath::remotePath): $pair" }
    $local = if ([System.IO.Path]::IsPathRooted($parts[0])) { $parts[0] } else { Join-Path $RepoRoot $parts[0] }
    $remote = $parts[1]
    if (-not (Test-Path $local)) { throw "転送元が見つかりません: $local" }
    $scpArgs = @($sshOpts)
    if ((Get-Item $local).PSIsContainer) { $scpArgs += "-r" }
    $scpArgs += @($local, "${User}@${Ip}:${remote}")
    & scp @scpArgs
    if ($LASTEXITCODE -ne 0) { throw "scp に失敗しました: $local -> $remote" }
}

if ($Command) {
    & ssh @sshOpts "${User}@${Ip}" $Command
    exit $LASTEXITCODE
}
exit 0
