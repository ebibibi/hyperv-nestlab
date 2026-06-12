# 0014 — RDP を開けたのに `Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'` で穴が開かない

L1/L2 Windows の RDP を既定有効化する処理 (`Initialize-L1Network.ps1` /
`Initialize-L2Access.ps1`) を入れたが、L0 から L1 へ RDP できなかった件。
(日本語ロケール一般の罠は [[0008]] も参照。)

## 症状

L0 から `mstsc /v:10.20.0.20` で L1 に接続すると、ネゴシエーション中に切断:

```
クライアントで検出されたプロトコル エラーのため (コード 0x1104)、このセッションは切断されます。
エラー コード: 0x1104  /  拡張エラー コード: 0x0
```

L1 側を調べると RDP 自体は起動しているのに、L0 からは 3389 に**TCP すら届かない**:

```
fDenyTSConnections : 0          # RDP 受付は ON
TermService        : Running     # サービス稼働
Listen3389         : 2           # 待ち受けあり (IPv4/IPv6)
SSLCertificateSHA1Hash : 設定済み # 自己署名証明書も生成済み (event 1056)

Test-NetConnection 10.20.0.20 -Port 3389  →  TcpTestSucceeded : False   # ★届かない
```

## 原因

**ファイアウォール規則の「表示グループ」名はロケールで翻訳される。** L1 は `ja-JP`
(`Get-WinSystemLocale` = ja-JP) なので、RDP の規則群の `DisplayGroup` は英語の
`Remote Desktop` ではなく **「リモート デスクトップ」** になっていた。

```
Name                          DisplayGroup            Enabled
----                          ------------            -------
RemoteDesktop-UserMode-In-TCP リモート デスクトップ      False   ← 開いていない
RemoteDesktop-UserMode-In-UDP リモート デスクトップ      False
```

そのため `Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'` は**1件もマッチせず、
規則は Disabled のまま**。3389 は閉じたままだった (`fDeny`/サービス/証明書は揃っていたので
「設定したのに繋がらない」と紛らわしい)。

加えて当初の実装には**二重のバグ**があった: RDP ブロックを
`if ((Get-ItemProperty ...).fDenyTSConnections -ne 0) { ... }` で囲っていたため、過去の実行で
`fDeny=0` だけは入った後の**再実行ではブロックごとスキップ**され、FW 開放が永遠に収束しなかった
(冪等性が「全部入った状態」でなく「fDeny だけ入った状態」に張り付く)。

## 対策

`Enable-NetFirewallRule` を**ロケール非依存の `-Name`** で叩く。RDP 既定規則の Name は
翻訳されない安定 ID:

```powershell
Enable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-TCP','RemoteDesktop-UserMode-In-UDP'
```

あわせて状態チェックの `if` ガードを撤去し、`fDeny=0` / `UserAuthentication=1` / FW 開放を
**毎回無条件に収束**させる (いずれも冪等。`Initialize-L1Network.ps1` / `Initialize-L2Access.ps1`
の RDP ブロック)。修正後 `TcpTestSucceeded : True` になり mstsc が通る。

`-DisplayGroup`/`-Group '@FirewallAPI.dll,-28752'` という代替もあるが、規則 Name 指定が
いちばん明示的で読みやすい。

## 教訓 / 汎用ノウハウ

- **ファイアウォール/規則を名前で操作するときは表示名 (DisplayName/DisplayGroup) を使わない。**
  これらはロケールで翻訳される。`-Name`/`-Group` のような**不変の内部 ID** を使う。同根の罠は
  [[0008]] (日本語ロケールでの文字列マッチ崩れ)。
- **「設定したのに繋がらない」ときは層を分けて確認する。** RDP なら ①受付 (fDenyTSConnections)
  ②サービス (TermService) ③待ち受け (Listen 3389) ④証明書 ⑤**到達性 (Test-NetConnection)**。
  ①〜④が揃っていて⑤だけ False なら、ほぼファイアウォール。
- **冪等ブロックを状態フラグ 1 つで丸ごとガードしない。** 途中まで成功・残りが失敗すると、
  フラグだけ立って残りが永久に未収束になる。各サブステップを個別に冪等化し、毎回収束させる。
