# 0028 — KDC プロキシ (KpsSvc) は URL 予約が無いと「アクセスが拒否されました」で即停止する

## 症状

証明書を 443 にバインドし、`HttpsClientAuth` と `LibNames` も入れたのに、KpsSvc が起動しない。

```
fatal: [dc01]: FAILED! => {"changed": false,
  "msg": "Unhandled exception while executing module:
          Failed to start service 'KDC Proxy Server service (KPS) (KPSSVC)'."}
```

システムログにはこれだけが出る。

```
イベント 7023: KDC Proxy Server service (KPS) サービスは、次のエラーで終了しました:
              アクセスが拒否されました。
イベント 7036: KDC Proxy Server service (KPS) サービスは 実行中 状態に移行しました。
イベント 7036: KDC Proxy Server service (KPS) サービスは 停止 状態に移行しました。
```

**一瞬 Running になってから停止する**のが特徴。サービス自体は起動しかけている。

紛らわしいのは、`netsh http show sslcert ipport=0.0.0.0:443` が正しい拇印と AppId
`{5d8e2743-ef20-4d38-8751-7e400f200e65}` を返すこと。証明書まわりは完全に正しく見える。

## 原因

KpsSvc は `svchost.exe -k KpsSvcGroup` の **NT AUTHORITY\NetworkService** で動き、起動時に
HTTP.SYS へ `https://+:443/KdcProxy` を登録しようとする。この **URL 予約 (urlacl) が無い**と、
非特権アカウントは URL を予約できず、アクセス拒否で落ちる。

```powershell
netsh http show urlacl | Select-String KdcProxy   # 何も返らない
```

通常は **RD ゲートウェイ役割**の構成時に urlacl が作られるため、役割を入れずに KDC プロキシだけを
単体で立てると、この一手だけが抜ける。証明書バインドとレジストリ設定の手順はよく紹介されているが、
urlacl に触れていない記事が多い。

## 対策

`https://+:<port>/KdcProxy` を NETWORK SERVICE へ予約する。

```powershell
$acct = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-20')).
        Translate([System.Security.Principal.NTAccount]).Value
netsh http add urlacl url=https://+:443/KdcProxy user="$acct"
Start-Service KPSSVC
```

アカウント名は SID `S-1-5-20` から引く。`"NT AUTHORITY\NETWORK SERVICE"` と直書きすると
英語以外のロケールで解決に失敗することがある。

**存在判定は末尾スラッシュ付きで行う。** HTTP.SYS は予約を `https://+:443/KdcProxy/` の形で保持するため、
`netsh http show urlacl url=https://+:443/KdcProxy`（スラッシュ無し）は予約済みでも何も返さない。
これを「未登録」と誤判定して `add` すると exit 1 で落ちる。一覧を引いて文字列一致させるのが確実。

本リポジトリでは `ansible/roles/kerberos_kdcproxy/tasks/server.yml` が冪等に実施する。

## 確認

```powershell
(Get-Service KPSSVC).Status                                      # Running
Get-NetTCPConnection -State Listen -LocalPort 443 | Measure-Object  # 1 以上
```

Running でも 443 が LISTEN していなければ証明書バインド側が原因なので、切り分けはこの 2 つで足りる。

## 補足: 秘密鍵の ACL は別問題（これだけでは直らない）

`New-SelfSignedCertificate` は秘密鍵の ACL を SYSTEM / Administrators にしか与えない。
`C:\ProgramData\Microsoft\Crypto\Keys\<UniqueName>` に NETWORK SERVICE の読み取りを足すのも
併せてやっておくべきだが、**今回の 7023 はこれを足しても直らず、urlacl を足した瞬間に Running になった**。
症状が同じなので混同しやすい。**先に urlacl を疑う。**
