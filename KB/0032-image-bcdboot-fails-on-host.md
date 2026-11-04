# 0032 — Windows 11 イメージの bcdboot がホスト上で失敗する

## 症状

Windows 11 の golden 生成で、展開は終わるのに次で止まる。

```
[win-dism] bcdboot で UEFI ブート構成
[win-dism] 失敗: bcdboot に失敗しました。
```

メッセージは何も出ず、終了コードだけが `-1058471934` (0xC0E90002) になる。

## 原因

展開したイメージの `W:\Windows\System32\bcdboot.exe` を、Windows Server 2025 のホスト上で直接起動しているため。
Windows 11 Enterprise 評価版 ja-jp (10.0.26100.6584) で再現した。Windows Server 2025 のイメージ
および別版の Windows 11 メディアでは同じ呼び出しが成功しているので、メディアの版に依存する。
起動できない根本の理由までは特定していない。

## 対策

`scripts/Build-WindowsGoldenDism.ps1` で、イメージ側が失敗したらホスト側の bcdboot で再試行する。
ホスト側の bcdboot は同じ `W:\Windows` に対して成功し、ブートファイルを作成した。

## 教訓 / 汎用ノウハウ

- 外部コマンドは終了コードだけでなく出力もエラーへ含める。今回は原因の切り分けに再現手順が要った。
- 別 OS のイメージ内の実行ファイルは、ホストで動く保証がない。
