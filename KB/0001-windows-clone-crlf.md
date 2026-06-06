# 0001 — Windows clone の CRLF が Linux 側ファイルを壊す

## 症状

GitHub から **Windows で `git clone`** したリポジトリで bootstrap を回すと、制御 VM (Linux) に
転送したファイルが壊れて落ちる。

```
set: -<CR>: invalid option           # bash here-string の行末に CR が混入
/usr/bin/env: 'python3\r': No such file or directory   # 動的インベントリの shebang が CRLF
```

ローカルで編集・実行している分には再現せず、「他人がまっさら clone したら壊れる」タイプの
いやらしいバグ。

## 原因

Git の `core.autocrlf=true` (Windows の既定) は、チェックアウト時にテキストを **CRLF** に変換する。
このリポジトリには Windows 側で動く `.ps1` と、**Linux 側で解釈される** ファイル
(`ansible/inventory/*.py` の shebang、bash に食わせる here-string、`.sh` / `.yml` / `.j2`) が混在する。
後者が CRLF になると、Linux の `bash` / `env` / `python3` が行末の `\r` をリテラルとして扱い壊れる。

## 対策

3 重で防ぐ (commit b5a31ee 系):

1. **`.gitattributes` で Linux 物を LF 固定**。これが本丸。
   ```
   *.ps1 *.psm1 ... text eol=crlf
   *.py *.yml *.yaml *.cfg *.ini *.sh *.j2 *.json text eol=lf
   *.iso *.vhdx *.vhd *.img binary
   ```
2. `control-node/Invoke-Ansible.ps1` が制御 VM へ同期した後、`find ~/nestedlab ... -exec sed -i 's/\r$//'`
   で念のため CR を除去。
3. 同スクリプトが bash へ渡す here-string を `-replace "`r`n","`n"` で LF 正規化してから送る。

## 教訓 / 汎用ノウハウ

- **クロスプラットフォームのリポジトリには必ず `.gitattributes` を置く。** README より先に置くくらいでいい。
  「自分の環境では動く」は、改行コードのバグを一番見逃しやすい。
- Linux で動く成果物を Windows 開発機から配るパイプラインでは、転送境界に **LF 正規化の保険**
  (`sed -i 's/\r$//'`) を一段入れておくと、`.gitattributes` の取りこぼし (zip 配布・コピペ生成
  されたファイル等) も拾える。
- 検証は必ず**まっさらな clone** から。手元の作業ツリーは autocrlf の影響を受けていないことがある。
