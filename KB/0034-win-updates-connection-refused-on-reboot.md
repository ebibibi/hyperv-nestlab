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

更新の適用後、ゲストは 1 回では終わらず再起動を繰り返す。実機の System ログ (1074) では、
`shutdown.exe` の再起動の約 8 分後と約 12 分後に、`TrustedInstaller.exe` がさらに再起動していた。
途中で WinRM が一度上がるので、再起動の完了待ちを抜けたあとに次の再起動で接続を失う。

## 対策

`ansible/roles/l2_config/tasks/windows_update_round.yml` で次を最大 6 ラウンド繰り返す。

1. `win_updates` を `reboot: false` で実行する
2. 再起動が必要なら `ansible.windows.win_reboot` で再起動する
3. 見つかった更新が 0 件になったら終える
4. 途中で接続を失ったら `rescue` で接続を作り直し、ゲストの復帰を待って次のラウンドへ進む

全ラウンドで終わらなければ、`main.yml` の `assert` で失敗させる。

## 教訓 / 汎用ノウハウ

- `win_reboot` の成功は「再起動が全部終わった」ことを意味しない。更新後は追加の再起動を前提にする。
- 再起動を含む処理を `until` で包んでも、接続の状態は作り直されない。
- 失敗と表示されても、再起動を含む処理は実体を確認する。逆に、成功と表示されても実体は確認する。
