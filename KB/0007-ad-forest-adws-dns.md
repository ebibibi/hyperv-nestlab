# 0007 — 入れ子 dcpromo は ADWS と DNS ゾーンを作り切らない

入れ子環境で AD フォレストを冪等に立てる (`scripts/Initialize-AdForest.ps1`) 際の 2 つのハマり。

## ハマり A: ADWS が起動しきらず Get-ADDomain が偽になる

### 症状
DC は昇格済みのはずなのに、フォレスト存在チェック (`Get-ADDomain`) が失敗し、「フォレストが
立ち上がらなかった」と誤判定。冪等再実行のたびに昇格をやり直そうとする。

### 原因
入れ子 + リソース制約下では、昇格後/再起動後に **ADWS (Active Directory Web Services) が自動起動
しきれない**ことがある。`Get-ADDomain` 等の AD PowerShell cmdlet は ADWS 経由なので、サービスが
上がっていないと「AD が無い」ように見える。

### 対策
AD 操作の前に **ADWS を明示起動**してから探る (`Initialize-AdForest.ps1`):
```powershell
Set-Service ADWS -StartupType Automatic
Start-Service ADWS
# その後 Get-ADDomain を最大 900s リトライ (昇格直後の立ち上がり待ち)
```
フォレスト存在プローブと昇格後待機の両方でこれを行う。

## ハマり B: dcpromo が DNS の前方参照ゾーンを作り切らない

### 症状
メンバ (mem01) のドメイン参加が:
```
ドメイン "corp.contoso.local" に接続できませんでした (domain cannot be contacted)
```

### 原因
入れ子昇格では、**dcpromo が DNS 前方参照ゾーンと SRV レコードを作り切らない**ことがある。
ゾーンや `_ldap._tcp` 等の SRV が無いと、メンバが DC を見つけられず参加に失敗する。

### 対策
DC 確認できたら**毎回 DNS の健全化**を実行 (`Initialize-AdForest.ps1`):
```powershell
if (-not (Get-DnsServerZone -Name $fqdn)) {
  Add-DnsServerPrimaryZone -Name $fqdn -ReplicationScope Forest -DynamicUpdate Secure
}
Restart-Service Netlogon      # SRV レコードを再登録
ipconfig /registerdns
```
検証では、ゾーン作成 → SRV 解決可能 → mem01 参加成功、まで確認済み。

## 教訓 / 汎用ノウハウ

- **「DC が昇格済み」と「AD が応答する」は別。** 入れ子/低リソースでは ADWS の起動が遅延/失敗する。
  AD cmdlet を叩く前に **ADWS を明示起動 + リトライ待機**を入れる。`Get-ADDomain` の失敗を
  「フォレスト無し」と短絡しない (冪等性を壊す)。
- **dcpromo の DNS 構成は信用しきらない。** 特に入れ子では前方参照ゾーン / SRV が欠けることがある。
  昇格後に**冪等な DNS 健全化ステップ** (ゾーン作成 + Netlogon 再起動 + registerdns) を毎回流すと、
  メンバ参加の「ドメインに接続できない」を根治できる。
- 健全化は**毎回流せる冪等な形** (存在チェック付き) にしておくと、再実行でも無害で効く。
