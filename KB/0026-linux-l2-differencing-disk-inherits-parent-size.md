# 0026 — Linux L2 の容量が宣言どおりにならない（差分ディスクは親のサイズを継承する）

## 症状

L2 Linux に何かを入れようとすると **No space left on device** で落ちる。宣言では
`disk_gb: 80`（既定）を指定しているのに、ゲストの `/` は数 GB しかない。

Azure Arc のエージェント導入 (85MB のパッケージ) で踏んだ例:

```
dpkg: error processing archive .../azcmagent_1.66.03466.1193_amd64.deb (--unpack):
 cannot copy extracted data for './opt/GC_Ext/GC/libvalidator.so' to
 '/opt/GC_Ext/GC/libvalidator.so.dpkg-new': failed to write (No space left on device)
```

L1 側で見ると、L2 の OS ディスクは**仮想サイズ 3.5GB** のままだった:

```powershell
Get-VMHardDiskDrive -VMName arclnx01 | ForEach-Object { Get-VHD $_.Path } |
  Select-Object Path, @{n='MaxGB';e={$_.Size/1GB}}
# arclnx01-os.vhdx : 3.5GB   ← 宣言は 80GB
```

## 原因

L2 の OS ディスクは、ベースイメージ (golden / cloud image) からの
**差分(ディファレンシング)ディスク**として作られる。差分ディスクの容量は**親のサイズで決まり、
子だけを大きくすることはできない**（`Resize-VHD` は差分ディスクに対して失敗する）。

Windows は golden を DISM で 40GB に焼いているため露呈しない。一方 **Ubuntu cloud image は
仮想 3.5GB** で配布されており、そのまま親になっていた。結果、宣言の `disk_gb` は
**Linux L2 に対してだけ無言で無視される**状態だった。

さらに紛らわしいことに、ゲストは起動する。cloud-init の growpart が「3.5GB の親いっぱい」まで
広げるので、**df は健全に見える**（使用率だけが妙に高い）。容量不足は「後から何かを入れたとき」に
初めて出るため、構築フェーズは全部成功して見える。

## 対策

**子を作る前に、親 (ベース VHDX) を宣言サイズへ拡張する。** `scripts/Expand-LinuxBaseImage.ps1`
を追加し、bootstrap のイメージ配送 (4g) の直前に実行する。

```powershell
# 確定モデルの Linux VM から os ディスクの最大 size_gb を読み、親がそれ未満なら広げる
Resize-VHD -Path assets\ubuntu2404-cloudimg.vhdx -SizeBytes ([int64]$targetGb * 1GB)
```

- 動的 VHDX の拡張は**メタデータ変更**なので一瞬で終わり、ファイル実体はほとんど増えない。
- ゲスト側のパーティション/ファイルシステムは **cloud-init の growpart** が起動時に広げるので、
  追加の作業は要らない。
- 冪等: 既に目標以上なら何もしない。
- **VM に接続中の VHDX は拡張できない**ため、対象は L0 の `assets/` にある配送元だけにする。
  L1 側のコピーは `Copy-GoldenToL1.ps1` のサイズ比較で不一致になり、自動的に再配送される。
- 既に作成済みの L2 がある状態では親を拡張できない（子が参照中）。その場合は**先に L2 を削除**する。

## 教訓 / 汎用ノウハウ

- **差分ディスクを使う設計では、容量は「親の属性」であって「子の宣言」ではない。** 宣言的な基盤で
  `disk_gb` のようなフィールドを持つなら、**差分の親側にそれを反映する経路**を必ず作る。無いと
  宣言が無言で無視される（最悪の失敗の仕方＝エラーが出ない）。
- **同じフィールドが OS によって効いたり効かなかったりする状態を放置しない。** ここでは Windows
  (40GB golden) では効き、Linux (3.5GB cloud image) では効かなかった。片方で動いていると
  「実装済み」と誤認する。
- **「起動する」は「正しく構成された」ではない。** growpart が親いっぱいまで広げてくれるせいで、
  df の見た目は正常だった。容量のような**上限系の設定は、上限そのものを検証する**
  (`Get-VHD .Size` を宣言値と突き合わせる) 必要がある。
