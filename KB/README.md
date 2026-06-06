# KB — hyperv-nestlab 開発ナレッジベース

このディレクトリは、hyperv-nestlab を作る中で**実際にハマったポイント**を記事として書き溜める場所です。
「同じ罠に二度はまらない」ためのトラブルシュート記録であると同時に、Nested Hyper-V / Ansible /
Windows golden / S2D まわりの**汎用ノウハウ集**でもあります。

## 書き方のルール

- ハマったら**ここに記事を足す**。Claude のメモリ (`.claude/.../memory`) には書かない。
  メモリはプロジェクトの「状態・ゴール・約束ごと」専用。技術的なハマりどころは全部この KB に。
- 1 記事 = 1 つのハマり (または密接に関連する 1 群)。ファイル名は `NNNN-kebab-title.md`。
- 各記事は次の見出しで揃える:
  - **症状** — 何が起きたか (エラーメッセージは原文で)
  - **原因** — なぜ起きたか (根本原因)
  - **対策** — どう直したか (該当コミット/ファイルへの参照)
  - **教訓 / 汎用ノウハウ** — 次に活かせる一般化
- コードやファイルを指すときは `path:line` 形式で。

## 記事一覧

| # | タイトル | 一言 |
|---|---------|------|
| [0001](0001-windows-clone-crlf.md) | Windows clone の CRLF が Linux 側ファイルを壊す | `.gitattributes` で LF 固定 |
| [0002](0002-control-node-ansible-deps.md) | 制御VMには ansible-core しか入っていない | collection / pywinrm を版固定導入 |
| [0003](0003-nested-l2-reachability-router.md) | 制御VMから L2 へ届かない (ルータ化 + ルーテッド LabNAT) | NetNat をやめて L1 をルータに |
| [0004](0004-windows-golden-dism-datacenter.md) | DISM だけで golden を焼く / S2D には Datacenter 必須 | エディション選択の罠 |
| [0005](0005-multi-language-iso.md) | 言語別 ISO のダウンロード冪等性 | 冪等キーはファイル名単位で |
| [0006](0006-nested-s2d-cluster.md) | 入れ子フェイルオーバークラスタ + S2D | CredSSP 二段ホップ / cluster cmdlet の罠 |
| [0007](0007-ad-forest-adws-dns.md) | 入れ子 dcpromo は ADWS と DNS ゾーンを作り切らない | 昇格後の健全化が要る |
| [0008](0008-win-powershell-gotchas.md) | ansible win_powershell の落とし穴 | 引数は文字列 / エラー握りつぶし / ロケール |
| [0009](0009-control-vm-rootfs-resize.md) | cloud イメージの rootfs が小さすぎる | 起動前に VHD 拡張 |
| [0010](0010-build-order-hyperv-first.md) | L1 内 Hyper-V は labstore/L2 より先に入れる | `Set-VMHost`/`New-VM` の前提 |
| [0011](0011-control-vm-memory-ssh-hang.md) | 制御VMのメモリ枯渇で scp/ansible が無限ハング | 動的メモリ下限 + SSH keepalive |
