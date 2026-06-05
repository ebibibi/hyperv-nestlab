# Linux golden イメージ (Phase 3)

Linux は cloud-init を使うため、多くの場合 distro 公式の **cloud image (VHDX 変換)** を
ベンダリングして使うのが最短・最も決定的。Packer ビルドは必要時のみ。

方針:
- Ubuntu 24.04 等の公式 cloud image を取得 → チェックサム検証 → VHDX 変換 → `assets/` に固定。
- インスタンス固有設定 (ホスト名 / IP / SSH 鍵) は cloud-init の seed ISO で L2 作成時に注入。
- イメージは `ansible/group_vars/all.yml` の `images` カタログから論理名で参照。
