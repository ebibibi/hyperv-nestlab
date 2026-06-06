# 0009 — cloud イメージの rootfs が小さすぎる

## 症状

制御 VM (Ubuntu cloud イメージ) で pip / ansible-galaxy の依存導入 ([[0002]]) が途中で:

```
No space left on device
```

## 原因

Ubuntu の **cloud イメージは rootfs が既定で ~3.5GB** と小さい。VHD のサイズを大きくしても、
**パーティション/ファイルシステムは自動では広がらない**ので、pip パッケージや collection を
入れると即座に枯渇する。

## 対策

`scripts/Ensure-ControlNode.ps1` が**初回起動の前に** OS ディスクを拡張する:

```powershell
Resize-VHD -Path $osDisk -SizeBytes 32GB
```

cloud-init の **`growpart`** が初回ブートでパーティションと rootfs を VHD いっぱいに自動拡張する。
VHD を先に広げておくのがポイント (起動後だと growpart が走り終わっている)。

## 教訓 / 汎用ノウハウ

- **cloud イメージ = 最小 rootfs。** 「ディスクを大きく作った」だけでは中身は広がらない。
  VHD/ディスクのサイズ拡張と、ゲスト内のパーティション/FS 拡張 (`growpart` / `growfs` / cloud-init)
  は**別物**。両方揃って初めて使える容量になる。
- 拡張は**初回ブートより前**に。cloud-init の growpart は初回起動時に 1 回走るので、VHD を
  先に広げておけば追加の手作業なしに rootfs まで自動で伸びる。
- 「依存を入れたら No space」を見たら、まず `df -h` で rootfs の実サイズを疑う (VHD サイズではなく)。
