# 0013 — 再アタッチされたラボストアがオフラインで「RAW ディスクが見つかりません」

## 症状

別 L2 構成への切替や再実行で、ラボストア (L:) 増設の段で失敗する:

```
==> L1 にラボストア(L:)を増設・初期化 (golden/L2 の置き場)
  [labstore] ラボストアを L1 へ SCSI ホットアド
  [labstore] L1 への PowerShell Direct セッションを待機
Exception: scripts\Add-L1LabStore.ps1:81
  L1 内に未初期化 (RAW) ディスクが見つかりません。ホットアドを確認してください。
```

L1 の中を見ると、ラボストアディスク (300GB) は**ちゃんと存在するが Offline**:

```
Number OperationalStatus PartitionStyle SizeGB
------ ----------------- -------------- ------
     0 Online            GPT                40   ← OS
     1 Offline           GPT               300   ← ラボストア (既存データあり)
```

## 原因

`Add-L1LabStore.ps1` の L1 側初期化が **2 分岐しかなかった**:

1. `Get-Volume` に `LabStore` ラベルがある → 既存とみなしスキップ。
2. なければ `PartitionStyle -eq 'RAW'` のディスクを初期化。

ところが「**既に初期化済み (GPT) だがオフライン**」のディスクはこのどちらにも当たらない:

- オフラインのディスクはボリュームがマウントされないので `Get-Volume` に `LabStore` が**出ない**。
- かといって `RAW` でもない (GPT)。

→ 両分岐から漏れて「RAW が見つからない」で誤って失敗する。

**なぜオフラインで戻るのか:** 既存データを持つデータディスクをホットアド/再アタッチすると、
Windows の SAN ポリシー既定によりオフライン (かつ読取専用) で現れることがある。初回構築では
ディスクが RAW なのでこの分岐に入らず通る。**2 回目 (GPT 化済み) で初めて踏む**典型的な
「クリーンは通る・再実行で壊れる」パターン (cf. [[0011-control-vm-memory-ssh-hang]],
[[0012-l1-uplink-pick-by-mac]])。

## 対策

LabStore ボリュームが見つからないとき、**RAW を探す前にオフラインディスクをオンライン化**して
再評価する分岐を追加 (`scripts\Add-L1LabStore.ps1`):

```powershell
$vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'LabStore' }
if (-not $vol) {
    $offline = Get-Disk | Where-Object { $_.OperationalStatus -ne 'Online' -or $_.IsOffline }
    foreach ($d in $offline) {
        try { Set-Disk -Number $d.Number -IsReadOnly $false } catch {}
        try { Set-Disk -Number $d.Number -IsOffline  $false } catch {}
    }
    if ($offline) { Start-Sleep 2; $vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'LabStore' } }
}
if (-not $vol) { <# ここで初めて RAW を探して初期化 #> }
```

オンライン化は「まだ LabStore が無いとき」だけに限定するので、初回 RAW 構築の邪魔をしない。
ドライブレターは GPT に永続するので、オンライン化すれば元の L: で復帰する。

## 教訓 / 汎用ノウハウ

- **「存在/RAW」の二値で状態を判定しない。** ディスクは Online/Offline、ReadOnly、ドライブレター
  有無など複数軸の状態を持つ。「既存ならスキップ / 無ければ作る」の二分木は、間の状態
  (初期化済みだがオフライン等) を取りこぼす。**まず正常状態へ収束させてから**存在判定する。
- **ホットアド/再アタッチしたデータディスクはオフライン前提で扱う。** 既存データ持ちは
  オフライン+読取専用で来うる。冪等スクリプトは黙ってオンライン化する処理を持つべき。
- ここでも「初回は RAW で通り、再実行で GPT になって壊れる」= 状態が時間で変わるバグ。
  **冪等性は最低 2 回まわすまで検証できない。**
