# 0002 — 制御VMには ansible-core しか入っていない

## 症状

制御 VM (cloud-init で立てた Ubuntu) で playbook を流すと、最初のタスクから落ちる。

```
couldn't resolve module/action 'ansible.windows.win_ping'
...
No module named 'winrm'
```

## 原因

- cloud-init の `packages:` / pip で入れていたのは **ansible-core だけ**。`ansible.windows` /
  `community.windows` などの **collection は別途インストールが要る** (ansible-core には同梱されない)。
- WinRM 接続には Python の **`pywinrm`** が必要で、これも入っていない。NTLM 認証では `pywinrm` が
  `requests_ntlm` を、CredSSP では `requests_credssp` を芋づるで連れてくるので、**extras 指定が要る**。

## 対策

`control-node/Invoke-Ansible.ps1` が制御 VM 上で、マーカーファイルで冪等化しつつ版固定導入する:

```bash
pip3 install --break-system-packages 'pywinrm[credssp]==0.4.3' \
  && ansible-galaxy collection install -r requirements.yml \
  && touch ~/.nestedlab-deps2-ok
```

- `pywinrm[credssp]` にすることで NTLM (requests_ntlm) と CredSSP (requests_credssp) の両依存が入る。
  → S2D クラスタ作成の二段ホップ ([[0006]]) で CredSSP transport を使うため必須。
- collection は `requirements.yml` で版を固定し、決定論性を担保 (原則②)。
- 到達性: pypi / galaxy へ出るのに CtrlNAT の NAT が必要。

## 教訓 / 汎用ノウハウ

- **「ansible が入っている」と「その playbook が要求する collection / Python ライブラリが入っている」は別。**
  ansible-core 単体は限りなく素。Windows を触るなら `ansible.windows` + `pywinrm`、CredSSP を使うなら
  `pywinrm[credssp]` まで含めて初めて動く。
- 依存導入は**マーカーファイル方式** (`~/.nestedlab-deps2-ok`) で冪等に。マーカー名にバージョンの
  通し番号 (`deps2`) を入れておくと、依存を変えたとき再インストールを強制できる。
- 版は必ず固定 (`==0.4.3`)。「最新が入る」は再現性の敵。

## 関連: 制御VM まわりの他のハマり

- **group_vars はインベントリ隣接に置く** (`ansible/inventory/group_vars/`)。動的インベントリ
  スクリプトの隣でないと読まれない。
- **scp 後の `ansible/` は world-writable になり ansible.cfg が無視される** (ansible のセキュリティ
  仕様)。`chmod -R go-w` で剥がす (Invoke-Ansible.ps1 で対応済み)。
