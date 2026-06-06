# 0004 — DISM だけで golden を焼く / S2D には Datacenter 必須

## 背景: なぜ Packer/ADK ではなく DISM か

原則① (前提は「Hyper-V があること」だけ) を満たすため、Packer/oscdimg/ADK といった**外部依存を
持たず**、Hyper-V + DISM 標準コマンドだけで golden VHDX を焼く方式を採った
(`scripts/Build-WindowsGoldenDism.ps1`)。手順は ISO マウント → 空 Gen2 VHDX に EFI/MSR/Windows
パーティション作成 → `Expand-WindowsImage` で直接展開 → `bcdboot` で UEFI ブート構成 →
`Panther\unattend.xml` 配置 (初回起動で OOBE 無人通過 + WinRM) → detach。無人インストールの起動すら不要。

## 症状 (本題のハマり)

2 ノードのクラスタで S2D を有効化しようとすると失敗:

```
Enable-ClusterStorageSpacesDirect : ノード 'fs01' で 記憶域スペースダイレクト はサポートされていません
0x80070032 (ERROR_NOT_SUPPORTED)
```

ネットワークもディスクも揃っているのに S2D だけ通らない。

## 原因

golden が **Standard エディション**だった。**S2D (記憶域スペースダイレクト) は Datacenter 専用機能**。
Standard では `Enable-ClusterStorageSpacesDirect` が `0x80070032` で必ず弾かれる。

## 対策

`Build-WindowsGoldenDism.ps1` の既定エディションを **Datacenter Evaluation (デスクトップ
エクスペリエンス)** に変更 (commit e063f82)。Datacenter は Standard の**上位互換**なので、S2D を
使わない他の全構成 (minimal / ad-forest / multi-lang) でもそのまま使える。

エディション選択は**言語非依存のパターンマッチ**で頑健化 (`Build-WindowsGoldenDism.ps1:79-88`):
1. 指定名で完全一致 → 2. `datacenter` + `eval` + (`desktop`|`デスクトップ`) → 3. `datacenter` + `eval`
→ 4. 保険で `standard` + `desktop`。日本語 ISO / 英語 ISO のどちらからでも golden を焼ける。

## 教訓 / 汎用ノウハウ

- **エンタープライズ機能のエディション要件を先に調べる。** S2D / Storage Replica / Shielded VM
  などは Datacenter 専用。ラボの golden は**最初から Datacenter Eval** にしておくのが無難
  (上位互換なので損がない)。`0x80070032 ERROR_NOT_SUPPORTED` を見たら、まずエディション/SKU を疑う。
- **install.wim のエディション名はロケールで変わる** ("Desktop Experience" / "デスクトップ
  エクスペリエンス")。固定文字列一致ではなく `-match` のパターン段階フォールバックで選ぶと、
  多言語 ISO ([[0005]]) でも壊れない。
- DISM 直展開 golden は「sysprep 済み」ではなく「unattend で specialize/oobe して各 VM 固有化」
  方式。Nested ラボには十分軽く、外部ツール 0 で済む。
