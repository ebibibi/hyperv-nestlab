# 0034 — `win_updates` が再起動中に接続を失って失敗する

## 症状

`windows_update: true` の構成で `ansible.windows.win_updates` が FAILED になり、bootstrap が失敗する。

```
requests.exceptions.ConnectionError: HTTPConnectionPool(host='dc01.corp.contoso.local', port=15985):
Max retries exceeded with url: /wsman (Caused by NewConnectionError ... [Errno 111] Connection refused
```

`until` で再試行しても、今度は次のエラーで全回失敗する。

```
kerberos.GSSError: (('No context has been established', 524288), ('Attempt to use incomplete security context', 39756039))
```

ゲストを確認すると、更新は適用済みでビルドも上がっている。

## 原因

`win_updates` の `reboot: true` で再起動すると、L2 へ L1 の NAT 越しに接続している WinRM が切れる。
そのあと同じタスクの再試行は切断前の Kerberos コンテキストを持ち越すらしく、回復しない
(再試行の間にゲストは正常に戻っている。プラグインの内部までは確認していない)。

## 対策

`ansible/roles/l2_config/tasks/windows_update_round.yml` で次を最大 4 ラウンド繰り返す。

1. `win_updates` を `reboot: false` で実行する
2. 再起動が必要なら `ansible.windows.win_reboot` で再起動する
3. 見つかった更新が 0 件になったら終える

## 教訓 / 汎用ノウハウ

- 再起動を含む処理を `until` で包んでも、接続の状態は作り直されない。再起動は専用のタスクに任せる。
- 失敗と表示されても、再起動を含む処理は実体を確認する。逆に、成功と表示されても実体は確認する。
