# 0034 — `win_updates` が再起動中の接続拒否で失敗する

## 症状

`windows_update: true` の構成で `ansible.windows.win_updates` が FAILED になり、bootstrap が失敗する。

```
requests.exceptions.ConnectionError: HTTPConnectionPool(host='dc01.corp.contoso.local', port=15985):
Max retries exceeded with url: /wsman (Caused by NewConnectionError ... [Errno 111] Connection refused
```

ゲストを確認すると、更新は適用済みでビルドも上がっている。

## 原因

`reboot: true` の再起動中に WinRM へ届かなくなり、モジュールがそのまま失敗扱いにしている。
L2 へは L1 の NAT 越しに接続するので、再起動中の接続は「タイムアウト」ではなく「拒否」で返る。
これがモジュールの再起動待ちを抜ける理由までは確認していない。

## 対策

`ansible/roles/l2_config/tasks/main.yml` の `win_updates` に `until` / `retries` / `delay` を付ける。
再実行すると残りの更新を処理し、無ければ成功で終わる。

## 教訓 / 汎用ノウハウ

- 失敗と表示されても、再起動を含む処理は実体を確認する。逆に、成功と表示されても実体は確認する。
