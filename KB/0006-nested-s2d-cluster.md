# 0006 — 入れ子フェイルオーバークラスタ + S2D

`l2/fileserver-s2d.yml` を実体化する `ansible/playbooks/create_cluster.yml` を作る過程で踏んだ罠。
(エディション要件は [[0004]]、到達性は [[0003]] を参照。)

## ハマり A: CredSSP の二段ホップ

### 症状
`New-Cluster` がドメイン操作で失敗。WinRM のログに:
```
the server returned an authentication mechanism: actual: Negotiate, Kerberos
```
クラスタ名オブジェクト (CNO) / 仮想計算機オブジェクト (VCO) を AD に作る段で認証が通らない。

### 原因
「制御 VM → L2 ノード → DC (AD に CNO/VCO を作成)」という**二段ホップ (double-hop)**。
NTLM/Negotiate では資格情報が 1 ホップ先までしか委譲されず、その先の AD 操作で資格情報が無くなる。

### 対策
クラスタ作成の play を **CredSSP transport + ドメイン管理者**で実行 (`create_cluster.yml:80-89`):
```yaml
ansible_user: "{{ domain.netbios }}\\Administrator"
ansible_winrm_transport: credssp
```
各ノードには事前に `Enable-WSManCredSSP -Role Server` を有効化 (`Initialize-L2Access.ps1` +
念押しで `create_cluster.yml` play1 でも実施)。制御 VM 側は `pywinrm[credssp]` ([[0002]]) が要る。

## ハマり B: cluster cmdlet の `-Name` / `-Cluster <名>` が DNS で死ぬ

### 症状
作成直後の検証で:
```
Get-Cluster -Name fscl : そのようなホストは不明です。 (no such host)
```

### 原因
`Get-Cluster -Name <名>` や `-Cluster <名>` は**名前を DNS 解決しに行く**。クラスタ作成直後は
CNO の DNS 登録が伝播しておらず解決できない。

### 対策
**メンバノード上でローカルに**クラスタ cmdlet を叩く (名前を渡さない):
`Get-Cluster` (引数なし) / `Get-ClusterQuorum` / `Get-ClusterStorageSpacesDirect` 等。
`run_once: true` のノードはクラスタメンバなので、これで自分のクラスタを操作できる
(`create_cluster.yml:99-107` ほか)。

## ハマり C: 入れ子環境の S2D はキャッシュ無しで

### 対策
入れ子の仮想ディスクは全て同種でキャッシュ用 NVMe 等が無いので、
`Enable-ClusterStorageSpacesDirect -PoolFriendlyName 'S2DPool' -CacheState Disabled` とし、
全ディスクを capacity として使う (`create_cluster.yml:141`)。これで 2 ノード入れ子でも S2D が有効化、
CSVFS_ReFS ボリューム + Scale-Out File Server + 継続可用共有まで通った。

## 教訓 / 汎用ノウハウ

- **AD オブジェクトを作る系の操作 (クラスタ/SQL/Exchange) は二段ホップになりがち。** 「actual:
  Negotiate, Kerberos」や「資格情報がもう一段先で失われる」症状を見たら **CredSSP** を疑う
  (サーバ側 `Enable-WSManCredSSP -Role Server` + クライアント側 `pywinrm[credssp]` の両輪)。
- **クラスタ/分散リソースの cmdlet は「名前指定」で DNS 依存になる。** 作成直後やプロビジョニング
  中は、対象ノード上で**ローカル実行 (引数なし)** する方が DNS 伝播待ちを避けられて堅い。
- **入れ子の S2D は `-CacheState Disabled`。** 物理のキャッシュ階層を前提にしたデフォルトは
  入れ子では成立しない。
- すべて**チェックしてから変更** (`Get-...` が無ければ作る) で冪等化。`New-Cluster` も既存
  `Get-Cluster` を見てからにする。
