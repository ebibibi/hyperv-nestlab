# 0020 — 追加ドメインコントローラーを足す（複製検証ができない問題）

## 症状

`l2/ad-forest.yml` の `domain.controllers` に DC を 2 台以上書いても、**2 台目以降が作られない。**
結果として「DC 間の複製」に関わる検証（複製の失敗、`repadmin /replsummary`、`dcdiag` の複製系テスト、
トゥームストーン超過など）が一切できない。

## 原因

`scripts/Initialize-AdForest.ps1` は先頭の 1 台だけを新規フォレストへ昇格する実装になっている。

```powershell
$dcs = @($cfg.vms | Where-Object { $_.provision.forest })
...
$dc = $dcs[0]      # ← 先頭のみ。2 台目以降は無視される
```

スキーマ（`schema.md`）は複数 DC を許しているため、宣言と実装が食い違っていた。

## 対処

`scripts/Add-LabDomainController.ps1` を追加した。既存ドメインへ **追加 DC** として 1 台足す。

```powershell
# 既定 (dc02 / 10.10.0.11) で追加
pwsh -File .\scripts\Add-LabDomainController.ps1

# 名前と IP を指定
pwsh -File .\scripts\Add-LabDomainController.ps1 -Name dc03 -IPAddress 10.10.0.12
```

処理は `Initialize-AdForest.ps1` と同じ二段 PowerShell Direct（L0 → L1 → L2）。
golden 複製 → VM 作成 → 静的 IP/DNS → 改名 → 再起動 → AD DS 導入 → `Install-ADDSDomainController`
→ 再起動 → 確認、という流れ。冪等（VM があれば作成をスキップ、昇格済みなら昇格をスキップ）。

## 踏んだ罠

### 1. 固定メモリだと起動できない（0x8007000E）

L1 のメモリ 32GB に対し、既存 L2（dc01 / mem01 / admin01）が **固定 8GB ずつ**で 24GB を占有していた。
追加 DC を固定メモリで作ると空きが足りず、起動時に次のエラーになる。

```
仮想マシン dc02 の起動に必要なメモリがシステムに不足しています。
メモリを初期化できませんでした ... (0x8007000E)
```

→ 追加 DC は **動的メモリ**（既定 2〜4GB）で作るようにした。既存 VM を止めずに追加できる。

### 2. 昇格直後は ADWS が起動していない（KB/0007 の再現）

昇格して DC にはなるが、**Active Directory Web Services (ADWS) が停止したまま**になることがある。
この状態だと、他の DC から `Get-ADReplicationPartnerMetadata -Scope Forest` を呼んだときに

```
サーバーと通信できません。... Active Directory Web サービスが実行されていない可能性があります
```

となり、**フォレスト全体の問い合わせが例外で丸ごと失敗する**（取得できていた分まで捨てられる）。

→ 昇格後に確認する。停止していれば起動する。

```powershell
Get-Service ADWS
Set-Service ADWS -StartupType Automatic
Start-Service ADWS
```

これは KB/0007（入れ子 dcpromo は ADWS と DNS ゾーンを作り切らない）と同じ根で、
**2 台目の DC でも再発する**ことが確認できた。

## 関連

- `KB/0007` 入れ子 dcpromo は ADWS と DNS ゾーンを作り切らない
- `KB/0016` PowerShell Direct は `-Credential` 必須
- `KB/0017` `.ps1` は pwsh 7 で実行（5.1 は BOM 無し UTF-8 を cp932 誤読）
