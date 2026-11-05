# 0033 — Windows 11 評価版が 1 時間で落ち、WinRM にも届かない

## 症状

`os: windows_11` の L2 で、次の 2 つが起きる。

1. Ansible が片方の PC だけ `UNREACHABLE` で止まる。
   ```
   fatal: [pc02]: UNREACHABLE! => ... port=15987): Max retries exceeded with url: /wsman (Caused by ConnectTimeoutError...
   ```
2. 起動から約 1 時間でゲストが電源オフになる。Hyper-V の記録は「ゲスト OS によってシャットダウン」(18508)。
   ゲストの System ログ (1074) には `C:\Windows\system32\wlms\wlms.exe` が開始したとある。

## 原因

1. `Enable-PSRemoting` は Windows 11 の WinRM を **遅延自動起動** にする (`sc.exe qc WinRM` が
   `AUTO_START (DELAYED)`)。Server と違い、起動直後の約 2 分は 5985 が開いていない。
2. 評価版はライセンス認証されるまで `License Status: Notification` / `0xC004F009 (grace time expired)`
   のままで、この状態だと WLMS が 1 時間ごとにシャットダウンする。Application ログのイベント 100/101 に
   `The operating system will shutdown every hour.` と出る。インターネットには出られる状態でも、
   待っているだけでは認証されなかった。

## 対策

- `scripts/Initialize-L2Access.ps1`: `sc.exe config WinRM start= auto` で遅延をなくす。
- `ansible/roles/l2_config/tasks/main.yml`: `windows_11` は構成の最初に `slmgr /ato` で認証する。
  手動で実行した確認では成功し、期限が 90 日後になった。

## 教訓 / 汎用ノウハウ

- VM が定期的に落ちるときは、まず System ログの 1074 で「誰が」落としたかを見る。
- Server で動く前提を、そのまま Windows クライアントへ持ち込まない。既定のサービス設定が違う。
