#!/usr/bin/env bash
# 制御 VM 上で WinRM クライアント一式が揃っているか検証する。
set -e
echo "=== python pywinrm ==="
python3 - <<'PY'
import importlib
m = importlib.import_module("winrm")
print("pywinrm OK", getattr(m, "__version__", "n/a"))
PY
echo "=== ansible core ==="
ansible --version | head -1
echo "=== ansible.windows collection ==="
ansible-galaxy collection list 2>/dev/null | grep -i ansible.windows || echo "MISSING ansible.windows"
echo "ALL_OK"
