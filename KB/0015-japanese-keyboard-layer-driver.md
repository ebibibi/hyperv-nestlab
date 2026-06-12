# 0015 — ja-JP なのにキーボードが英語(101)配列 / L1 のホスト名が変わらない

golden 由来の L1/L2 で、表示・ロケールは日本語 (ja-JP) なのに**キーボードの記号位置が
英語配列**になり、日本語ユーザーが戸惑う件。あわせて L1 のホスト名が golden 既定の
`WIN-xxxxx` のまま変わっていなかった件。

## 症状

- L1/L2 にログインすると言語・IME は日本語 (`Get-WinSystemLocale` = ja-JP、IME は 0411) なのに、
  `@ [ ] : * ( )` などの記号が**英語(US 101)配列の位置**に出る。`半角/全角`・`変換`・`無変換` も効かない。
- L1 の `ComputerName` が `WIN-5JJ9JF08VVN` のまま (resolved の `nested-lab-01` になっていない)。
  L2 は `Initialize-L2Access.ps1` が `Rename-Computer` するが、**L1 にはリネーム処理が無かった**。

## 原因

### キーボード
言語が ja-JP でも、**物理キーボードのレイヤドライバは別管理**。
`HKLM:\SYSTEM\CurrentControlSet\Services\i8042prt\Parameters` の
`LayerDriver JPN` 等が未設定だと、既定の US 101 として解釈される。golden はここが空のままだった:

```
LayerDriver JPN            : (空)
OverrideKeyboardIdentifier : (空)
OverrideKeyboardSubtype    : (空)
OverrideKeyboardType       : (空)
```

### ホスト名
`Initialize-L1Network.ps1` は静的 IP / WinRM / RDP までしか焼いておらず、`Rename-Computer` が
無かった。Ansible は IP (10.20.0.20) で繋ぐのでリネームしても自動化は壊れないが、利用者目線では
`WIN-xxxxx` のままだと分かりにくい。

## 対策

`Initialize-L1Network.ps1` / `Initialize-L2Access.ps1` の PowerShell Direct ブロックで、
106/109 キーボードのレイヤドライバを設定 (冪等):

```powershell
$kp = 'HKLM:\SYSTEM\CurrentControlSet\Services\i8042prt\Parameters'
Set-ItemProperty $kp -Name 'LayerDriver JPN'            -Value 'kbd106.dll'  -Type String
Set-ItemProperty $kp -Name 'OverrideKeyboardIdentifier' -Value 'PCAT_106KEY' -Type String
Set-ItemProperty $kp -Name 'OverrideKeyboardSubtype'    -Value 2            -Type DWord
Set-ItemProperty $kp -Name 'OverrideKeyboardType'       -Value 7            -Type DWord
```

L1 には `Rename-Computer -NewName <resolved l1 名>` を追加 (NetBIOS 制約に丸める / 15 文字)。
**いずれも反映に再起動が要る**ため、両スクリプトとも「変更があれば 1 度だけ `Restart-VM` →
PowerShell Direct で張り直して収束確認」というフローにした (L2 は既存の改名再起動に相乗り)。
冪等: 既に kbd106 / 目的名なら何もしない。

## 教訓 / 汎用ノウハウ

- **「日本語 Windows なのに英語キーボード」は言語設定では直らない。** 物理レイヤは
  `i8042prt\Parameters` のレイヤドライバ (`kbd106.dll` / `PCAT_106KEY` / subtype 2 / type 7)。
  反映には再起動が要る。golden を US で焼くと全 VM が US 101 になるので、golden 側で入れるか
  プロビジョニングで毎回収束させる。
- **再起動を伴う収束 (rename / keyboard) は「変更時だけ 1 回再起動 → 張り直して確認」に畳む。**
  複数の要再起動変更 (改名 + キーボード) はフラグを立てて**まとめて 1 回**で再起動する。
- **ホスト名は VM 名に揃えておくと運用が楽。** Ansible は IP 接続なので安全に改名できる。
  golden 既定の `WIN-xxxxx` を残さない。
