# 0029 — features を宣言していないモデルは configure_l2 が丸ごとスキップされる（無言）

## 症状

宣言に書いた OS 内構成が、bootstrap が成功しているのに一切適用されない。

    Get-SmbShare -Name labshare    # 何も返らない
    (Get-ItemProperty ...Kerberos\Parameters -Name LogLevel).LogLevel   # 空

`bootstrap.ps1` は `EXITCODE=0` で完走し、フェーズ別の所要時間一覧にも
**「L2: OS内構成」の行が出ない**。エラーが出ないので、ロール側を疑って時間を溶かす。

## 原因

`bootstrap.ps1` の 6b フェーズのガードが **features しか見ていなかった**。

```powershell
# 修正前
if ($model.vms | Where-Object { ($_.os -notmatch 'ubuntu|...') -and ($_.features) -and (@($_.features).Count -gt 0) }) {
```

`l2_config` ロールは features 以外に applications / smb_share / ntlm_audit / kerberos_debug も扱うが、
ガードはそれらを見ていない。そのため **features を 1 つも宣言していないモデルは、
他の項目をいくら書いても playbook 自体が呼ばれない。**

`l2/ad-forest.yml` が問題化しなかったのは、たまたま members グループに `features: [Web-Server, ...]` が
あり、ガードを通っていたため。applications だけを宣言したモデルは以前から静かに無視されていた。

## 対策

ガードは、その先のロールが扱う項目を**すべて**見る。

```powershell
$needsL2Config = $model.vms | Where-Object {
    ($_.os -notmatch 'ubuntu|debian|linux') -and (
        (@($_.features).Count -gt 0) -or
        (@($_.applications).Count -gt 0) -or
        ($_.smb_share) -or ($_.ntlm_audit) -or ($_.kerberos_debug)
    )
}
if ($needsL2Config) { ... }
```

## 一般化

**ガードの条件は、ガードの先が扱う入力の集合と一致させる。** 片方だけ足すと、
条件の外側に落ちた宣言が「書いたのに効かない」状態で残り、しかも成功扱いになる。
項目を増やすときは、ロールとガードを必ず同じコミットで更新する。
