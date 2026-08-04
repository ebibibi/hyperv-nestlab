#Requires -Version 5.1
<#
.SYNOPSIS
  Azure Arc オンボード用のサービスプリンシパルを作成し、build/arc-cred.json を書き出す。

.DESCRIPTION
  Arc-enabled servers への非対話オンボードには「Azure Connected Machine Onboarding」ロールを
  持つサービスプリンシパルが要る。このスクリプトは以下を冪等に行う:

    1. リソースグループを作成 (無ければ)
    2. サービスプリンシパルを作成 (同名があればシークレットだけリセット)
    3. そのリソースグループスコープに Azure Connected Machine Onboarding ロールを割り当て
    4. 資格情報を build/arc-cred.json へ書き出す (.gitignore 済み。リポジトリには入らない)

  出力ファイルは bootstrap.ps1 が自動で読む。宣言 (l2/*.yml の azure_arc) には
  接続先だけを書き、シークレットは書かない。

  前提: Azure CLI (az) が導入済みで、対象サブスクリプションに対して
  「サービスプリンシパルを作成しロールを割り当てられる」権限でサインイン済みであること。

.EXAMPLE
  .\scripts\New-ArcOnboarding.ps1 -SubscriptionId <sub> -ResourceGroup rg-nestlab-arc -Location japaneast

.EXAMPLE
  # 別名の SP を使う / 出力先を変える
  .\scripts\New-ArcOnboarding.ps1 -SubscriptionId <sub> -ResourceGroup rg-arc -Location eastus `
      -ServicePrincipalName sp-nestlab-arc -OutFile D:\arc-cred.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Location,
    [string]$ServicePrincipalName = "sp-hyperv-nestlab-arc",
    [string]$OutFile
)
$ErrorActionPreference = "Stop"
function Log($m) { Write-Host "  [arc] $m" -ForegroundColor DarkCyan }
function Fail($m) { Write-Host "  NG  $m" -ForegroundColor Red; exit 1 }

if (-not $OutFile) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $OutFile = Join-Path $repoRoot "build\arc-cred.json"
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Fail "Azure CLI (az) が見つかりません。https://aka.ms/installazurecli から導入してください。"
}

Log "サブスクリプションを選択: $SubscriptionId"
az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "サブスクリプションの選択に失敗しました。az login を確認してください。" }

$tenantId = (az account show --query tenantId -o tsv)
if (-not $tenantId) { Fail "テナント ID を取得できませんでした。" }

Log "リソースグループを確認/作成: $ResourceGroup ($Location)"
az group create --name $ResourceGroup --location $Location --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "リソースグループの作成に失敗しました。" }

# Arc のオンボードに必要な RP。未登録だと connect が失敗する。
Log "リソースプロバイダーを確認: Microsoft.HybridCompute / Microsoft.GuestConfiguration"
foreach ($rp in @("Microsoft.HybridCompute", "Microsoft.GuestConfiguration", "Microsoft.HybridConnectivity")) {
    $state = az provider show -n $rp --query registrationState -o tsv 2>$null
    if ($state -ne "Registered") {
        Log "  $rp を登録します (現在: $state)"
        az provider register -n $rp --wait | Out-Null
    }
}

$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$appId = az ad sp list --display-name $ServicePrincipalName --query "[0].appId" -o tsv 2>$null

if ($appId) {
    Log "既存のサービスプリンシパルを再利用し、シークレットをリセット: $ServicePrincipalName ($appId)"
    $secret = az ad sp credential reset --id $appId --query password -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $secret) { Fail "シークレットのリセットに失敗しました。" }
    Log "ロール割り当てを確認: Azure Connected Machine Onboarding @ $ResourceGroup"
    az role assignment create --assignee $appId --role "Azure Connected Machine Onboarding" --scope $scope --only-show-errors | Out-Null
} else {
    Log "サービスプリンシパルを作成: $ServicePrincipalName (スコープ: $ResourceGroup)"
    $sp = az ad sp create-for-rbac --name $ServicePrincipalName `
        --role "Azure Connected Machine Onboarding" --scopes $scope -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $sp.appId) { Fail "サービスプリンシパルの作成に失敗しました。" }
    $appId = $sp.appId
    $secret = $sp.password
}

# Run Command など「作った後に操作する」権限は onboarding ロールに含まれない。
# 運用主体 (人 / AI エージェント) 側に Azure Connected Machine Resource Administrator を
# 別途割り当てること (このスクリプトはオンボード専用の最小権限に留める)。

$cred = [ordered]@{
    subscription_id          = $SubscriptionId
    tenant_id                = $tenantId
    resource_group           = $ResourceGroup
    location                 = $Location
    service_principal_id     = $appId
    service_principal_secret = $secret
}
New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null
$cred | ConvertTo-Json | Set-Content -Path $OutFile -Encoding UTF8
# 所有者以外に読ませない (build/ は .gitignore 済みだが、ファイル権限でも守る)。
# 本スクリプトは pwsh 7 なら Linux/macOS でも動く (az があればどこで作ってもよい) ため、
# Windows 以外では Get-Acl/Set-Acl が無い。プラットフォームで分岐する。
try {
    if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) {
        $acl = Get-Acl $OutFile
        $acl.SetAccessRuleProtection($true, $false)
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, "FullControl", "Allow")))
        Set-Acl -Path $OutFile -AclObject $acl
    } else {
        & chmod 600 $OutFile
    }
} catch {
    Write-Host "  !!  ファイル権限の制限に失敗しました (処理は続行): $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  OK  資格情報を書き出しました: $OutFile" -ForegroundColor Green
Write-Host "      appId: $appId / tenant: $tenantId" -ForegroundColor DarkGray
Write-Host "      このファイルはリポジトリに入りません (build/ は .gitignore 済み)。" -ForegroundColor DarkGray
Write-Host "      bootstrap.ps1 はこのファイルを自動で読みます。" -ForegroundColor DarkGray
exit 0
