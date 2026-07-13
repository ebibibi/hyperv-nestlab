# 宣言設定スキーマ (schema.md)

> 本基盤の心臓部。利用者が書く YAML の構造・規則・既定値・検証方式を確定する。
> 方向性は `plan.md` で決めた **パターン C（ハイブリッド）**。
> このドキュメントの規則は JSON Schema (`schema/l1.schema.json`, `schema/l2.schema.json`) として機械検証可能な形でも提供する。

---

## 0. 全体像

- 設定は **L1 ファイルと L2 ファイルの 2 本** に分離する。
  - **L1**（`l1/*.yml`）= Nested Hyper-V ホストの定義。どの検証でも使い回す土台。
  - **L2**（`l2/*.yml`）= L1 の中に作る VM 群・ドメイン・クラスタの定義。検証ごとに差し替える。
- 展開は両方を指定して実行する：
  ```powershell
  .\bootstrap.ps1 -L1 l1\standard-host.yml -L2 l2\fileserver-s2d.yml
  ```
- 書き味は **「既定値で省略、必要な所だけ細かく」**。普段は短く、いざとなれば低レベルのフル明示まで降りられる（エスケープハッチ）。

---

## 1. 確定した設計判断（おすすめ採用）

### 1-1. 命名と連番（`count` / `ip_from`）
- グループは `count` 台を自動生成する。
- 各 VM 名 = `name_prefix` + ゼロ詰めインデックス。
  - `name_prefix` 既定値 = グループ `name`。
  - インデックスは `index_start`（既定 `1`）から、`index_width`（既定 `2`）桁でゼロ詰め。
  - 例：`name_prefix: fs`, `count: 2` → `fs01`, `fs02`。
- IP は `ip_from` を先頭に **連番**で採番する。
  - 例：`ip_from: 10.10.0.21`, `count: 2` → `fs01=.21`, `fs02=.22`。
  - サブネットは L1 の `network.nat.subnet` に従い、範囲外は検証で弾く。

### 1-2. 継承と優先順位（低 → 高）
```
L1.l2_defaults  <  L2.defaults  <  group（グループ直下の設定）  <  overrides（VM個別）
```
- 継承対象フィールド: `cpu` / `memory_gb` / `os` / `generation` / `domain_join` / `disk_gb` / **`language`** / `features` / `applications`。

### L2アプリケーションの宣言

Windows L2の `applications` には、現在 `claude_code` と `microsoft_word` を指定できる。AD参加とWinRM/Kerberos接続の確立後、`configure_l2.yml` が対象ホストだけへ冪等適用する。

```yaml
applications: [claude_code, microsoft_word]
```

- `claude_code`: Anthropic公式Windows native installerのstable channel。ドメイン管理者プロファイルに導入する。
- `microsoft_word`: Microsoft公式Office Deployment ToolでMicrosoft 365 Apps版Wordのみを導入する。ライセンス認証は利用者のサインイン後に行う。
- `language`（ゲスト言語）: 例 `en-us` / `ja-jp`。未指定は `en-us`。
  - **Windows**: その言語の ISO を自動取得し言語別 golden (`win2025-golden-<lang>.vhdx`) を生成。
  - **Linux**: 単一 cloud image + cloud-init で `locale`（例 `ja_JP.UTF-8`）を設定。
  - 利用可能言語と LCID は `assets/images.yml` の `windows_languages.catalog` / `linux_locales`。
  - **L1（ホスト）は常に `en-us` 固定**（安定性優先・複雑化回避）。
- スカラ／マップは **深いマージ**（deep merge）。
- リスト（`disks` / `nics` / `roles`）は **置換**（より具体的な層が丸ごと上書き）。予測しやすさを優先。
- `data_disks: {count, size_gb}` は糖衣。解決時に `disks:` の `role: data` 複数本へ展開される。`overrides` で `disks:` をフル明示した場合はそちらが優先（＝置換）。

### 1-3. `overrides` の粒度
- キーは **生成後の VM 名**（例 `fs01`）。
- 値はその VM の解決済みスペックへ深いマージ。**任意のフィールド**（`cpu` / `memory_gb` / `disks` / `nics` / `provision` …）を差し込める。
- これが「低レベル制御は死守」の担保。グループの一台だけ特殊化、なども可能。

### 1-4. シークレットの扱い
- 平文をリポジトリに置かない。値は **`"{{ vault.<key> }}"`** 形式で参照する。
- 実体は **Ansible Vault 暗号化ファイル** `secrets.yml`（雛形 `secrets.example.yml`）に置く。
- `bootstrap.ps1` は Vault パスワード（`-VaultPassword` もしくは環境変数）を制御ノードへ安全に受け渡す。
- スキーマ検証では `{{ ... }}` を含む文字列を「未解決の参照」として許容（型は string 扱い）。

### 1-5. 検証（壊れた YAML を早期に弾く）
- **正本は JSON Schema**（`schema/l1.schema.json`, `schema/l2.schema.json`, draft 2020-12）。
- 二段構えで fail-fast：
  1. **プリフライト（ホスト上 `bootstrap.ps1`）**：ファイル存在・YAML パース可否・トップレベルキーの基本チェック。同梱 Python（pyyaml + jsonschema）で **完全な JSON Schema 検証**まで実施する（本環境に Python があることが前提③に反しない範囲で確認済み）。
  2. **解決（resolver）後の整合チェック**：IP のサブネット内判定・重複名・重複 IP・クラスタノード数などの意味検証。
- どちらも **VM を 1 台も作る前に** 実行し、問題があれば中断する。

### 1-6. DNS の自動補完
- メンバーサーバの `nics[].dns` を省略した場合、`domain.controllers[0].ip` を自動設定する。
- DC 自身の DNS はループバック（`127.0.0.1`）を既定にする。

---

## 2. L1 スキーマ

```yaml
l1_host:
  name: nested-lab-01        # 必須。L0 上に作る Nested ホスト VM 名
  cpu: 8                     # 必須
  memory_gb: 32              # 必須。静的メモリ（動的メモリは強制 OFF）
  nested: true               # 既定 true。ExposeVirtualizationExtensions
  disk_gb: 160               # L1 の OS ディスク
  base_image: win2025-eval   # images カタログの論理キー
  network:
    nat:
      switch: LabNAT         # L1 内 Internal スイッチ名
      subnet: 10.10.0.0/24   # L1 内ネットワーク
      host_ip: 10.10.0.1     # L1 ホストの NAT ゲートウェイ IP
  l2_defaults:               # L2 全 VM の最下層の既定値
    generation: 2
    os: windows_server_2025
```

必須：`name`, `cpu`, `memory_gb`, `network.nat.{switch,subnet,host_ip}`。

---

## 3. L2 スキーマ

トップレベルキー：`defaults`（任意）, `domain`（任意）, `groups`（パターン C 推奨）, `vms`（パターン A：フル明示）, `clusters`（任意：明示クラスタ）。

### 3-1. `defaults`
全 VM に効く既定値（`group`/`overrides` で上書き可）。
```yaml
defaults:
  cpu: 4
  memory_gb: 8
  os: windows_server_2025
  domain_join: corp.contoso.local
```

### 3-2. `domain`
```yaml
domain:
  fqdn: corp.contoso.local
  netbios: CORP
  dsrm_password: "{{ vault.dsrm_password }}"
  controllers:
    - { name: dc01, ip: 10.10.0.10, cpu: 2, memory_gb: 4 }
```
`controllers` から DC VM を生成し、フォレスト/ドメインを構成する。

### 3-3. `groups`（パターン C の主役）
```yaml
groups:
  - name: fileservers
    name_prefix: fs          # 既定 = name
    count: 2
    index_start: 1           # 既定 1
    index_width: 2           # 既定 2
    ip_from: 10.10.0.21
    cpu: 4                   # group レベルの既定上書き
    memory_gb: 8
    data_disks: { count: 4, size_gb: 100 }   # → role:data ×4 に展開
    roles: [ File-Services, Failover-Clustering ]
    cluster:                 # 任意。あればこのグループでクラスタを構成
      name: fscluster
      ip: 10.10.0.30
      s2d: true
      witness: { type: fileshare, host: dc01 }   # host: 共有を置くサーバ名 (YAML予約語 on は使わない)
      role: { type: file_server, volume_gb: 200 }
    overrides:               # 任意。VM 個別の低レベル上書き
      fs01:
        cpu: 8
        disks:
          - { role: data, size_gb: 500 }
```

### 3-4. `vms`（パターン A：フル明示エスケープ）
`groups` で表現しづらい個体は、`vms:` に低レベルで直書きできる。`groups` と併用可。
```yaml
vms:
  - name: special01
    cpu: 8
    memory_gb: 16
    disks:
      - { role: os,   size_gb: 80 }
      - { role: data, size_gb: 200 }
    nics:
      - { switch: LabNAT, ip: 10.10.0.50, gw: 10.10.0.1, dns: 10.10.0.10 }
    provision:
      domain_join: corp.contoso.local
      roles: [ Web-Server ]
```

### 3-5. `clusters`（明示クラスタ）
`group.cluster` ではなく、既存ノードを参照してクラスタを定義する低レベル形。
```yaml
clusters:
  - name: fscluster
    ip: 10.10.0.30
    nodes: [ fs01, fs02 ]
    storage: { s2d: { enabled: true } }
    witness: { type: fileshare, path: \\dc01\witness }
    roles:
      - { type: file_server, name: fs, volumes: [ { name: data01, size_gb: 200, fs: ReFS } ] }
```

---

## 4. 解決済みモデル（resolver の出力）

resolver は L1 + L2 を読み、継承・連番・糖衣展開・自動補完を適用して**フラットな確定モデル**を出力する。Ansible はこれを唯一の入力とする。

```yaml
domain: { fqdn, netbios, dsrm_password, controllers: [...] }
vms:
  - name: fs01
    cpu: 4
    memory_gb: 8
    os: windows_server_2025
    generation: 2
    domain_join: corp.contoso.local
    disks:
      - { role: os,   size_gb: 80 }
      - { role: data, size_gb: 100 }   # ×4 に展開済み
      - ...
    nics:
      - { switch: LabNAT, ip: 10.10.0.21, gw: 10.10.0.1, dns: 10.10.0.10 }
    provision: { roles: [...], member_of: fscluster }
clusters:
  - { name: fscluster, ip: 10.10.0.30, nodes: [fs01, fs02], s2d: true, witness: {...}, roles: [...] }
```

---

## 5. 冒頭のゴール例（AD フォレスト + 2ノード S2D ファイルサーバ）の最終形

```yaml
# l2/fileserver-s2d.yml
defaults:
  cpu: 4
  memory_gb: 8
  os: windows_server_2025
  domain_join: corp.contoso.local

domain:
  fqdn: corp.contoso.local
  netbios: CORP
  dsrm_password: "{{ vault.dsrm_password }}"
  controllers:
    - { name: dc01, ip: 10.10.0.10, cpu: 2, memory_gb: 4 }

groups:
  - name: fileservers
    name_prefix: fs
    count: 2
    ip_from: 10.10.0.21
    data_disks: { count: 4, size_gb: 100 }
    roles: [ File-Services, Failover-Clustering ]
    cluster:
      name: fscluster
      ip: 10.10.0.30
      s2d: true
      witness: { type: fileshare, host: dc01 }
      role: { type: file_server, volume_gb: 200 }
```

これだけで「DC ×1（フォレスト）＋ファイルサーバ ×2（各 S2D 用 100GB×4）＋フェイルオーバークラスタ＋S2D＋ファイルサーバ役割」までを宣言できる。
低レベル制御が要るときは `overrides` / `vms` / `clusters` に降りる。
