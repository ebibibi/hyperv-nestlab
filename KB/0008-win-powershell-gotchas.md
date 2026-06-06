# 0008 — ansible win_powershell の落とし穴

`ansible.windows.win_powershell` を多用する中で繰り返し踏んだ罠。

## ハマり A: パラメータは文字列で渡る

### 症状
メモリ割り当て計算が `System.OutOfMemoryException` で死ぬ。

### 原因
`win_powershell` の `parameters:` で渡した値は、PowerShell 側に**文字列として**届く。
`"4" * 1GB` は数値演算ではなく**文字列の反復** (4 を 10 億回連結) になり、メモリを食い尽くす。

### 対策
スクリプト側で**型を明示**して受ける:
```powershell
param([int]$MemGB)
$bytes = $MemGB * 1GB     # ここで初めて数値演算
```

## ハマり B: 既定で非終端エラーを握りつぶす

### 症状
途中のコマンドが失敗しているのに、タスクは成功扱い。後段で初めて壊れて原因が分かりにくい。

### 原因
`win_powershell` は既定で**非終端エラーを握りつぶす** (changed/ok を返してしまう)。

### 対策
失敗を必ず表面化させる:
```yaml
ansible.windows.win_powershell:
  error_action: stop
  script: |
    $ErrorActionPreference = 'Stop'
    ...
```
両方 (`error_action: stop` と `$ErrorActionPreference='Stop'`) を付けるのが確実。

## ハマり C: ホストが日本語ロケールで、英語名の参照が効かない

### 症状
統合コンポーネントやサービスを英語名で引こうとすると見つからない。

### 原因
L0 ホストが**日本語ロケール**。表示名がローカライズされ、英語の固定文字列でマッチしない。

### 対策
**ID で特定する** (例: Guest Service Interface = `6C09BB55-8B74-4B89-...`)。または
`-match 'desktop|デスクトップ'` のように**両言語のパターン**で受ける ([[0004]] のエディション選択と同じ発想)。

## 教訓 / 汎用ノウハウ

- **オーケストレータ越しに渡る引数は型が落ちる前提で書く。** 受け側で `param([int]...)` 等を必ず宣言。
  「文字列 × 数値リテラル」の罠 (`"4"*1GB`) は静かに OOM するので特に注意。
- **「エラーで止まる」はデフォルトではない。** ラッパー (ansible / CI / リモート実行) は親切心で
  エラーを握りつぶしがち。明示的に fail-fast (`-ErrorAction Stop` + ラッパーの stop オプション) を入れる。
- **ロケール依存の表示名で物を引かない。** GUID/ID や両言語パターンで引く。多言語ラボ ([[0005]]) を
  作るなら最初からこの方針にしておく。
