#!/usr/bin/env bash
# Configure the control VM for Kerberos-authenticated WinRM to domain-joined L2 VMs.
#
# WHY: control(Linux, non-domain) -> member-server WinRM by IP + NTLM pass-through is
# rejected on a domain member (SEC_E_NO_CREDENTIALS / 0x8009030e). The reliable path is
# Kerberos: connect by FQDN, let Ansible's winrm plugin auto-kinit with the domain admin
# UPN + password. For that the control VM needs: an MIT krb5 config pointing at the DC as
# KDC, deterministic name resolution for the L2 FQDNs (we do not depend on the lab DNS from
# the control segment), the krb5 client tools, and pywinrm's kerberos extra. See KB/0019.
#
# Idempotent. Intended to run as root via sudo. Arg1 = path to resolved.json.
#   sudo bash Setup-ControlKerberos.sh ~/nestedlab/build/resolved.json
set -euo pipefail

MODEL="${1:?usage: sudo bash Setup-ControlKerberos.sh <resolved.json>}"
[ -r "$MODEL" ] || { echo "[Setup-ControlKerberos] model not readable: $MODEL" >&2; exit 1; }

# Generate /etc/krb5.conf and the managed /etc/hosts block from the resolved model.
# Runs as root (this script is sudo'd) so it can write under /etc. Prints "REALM KDC"
# on success, or "NONE" when the model declares no domain (nothing to configure).
INFO="$(python3 - "$MODEL" <<'PY'
import json, sys

m = json.load(open(sys.argv[1]))
d = m.get("domain")
if not d:
    print("NONE")
    sys.exit(0)

realm = d["fqdn"].upper()
realm_lower = d["fqdn"].lower()
kdc = m["l1"].get("management_ip", "10.20.0.20")

# Domain-participating Windows VMs: the DC carries provision.forest; members carry a
# truthy domain_join (the FQDN to join). Both need an FQDN->IP entry so Kerberos by name
# works from the control segment without relying on the lab DNS.
entries = []
for vm in m.get("vms", []):
    if not (vm.get("provision", {}).get("forest") or vm.get("domain_join")):
        continue
    nics = vm.get("nics") or []
    if not nics or not nics[0].get("ip"):
        continue
    entries.append((kdc, "%s.%s" % (vm["name"], realm_lower), vm["name"]))

krb5 = """[libdefaults]
    default_realm = %s
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    forwardable = true

[realms]
    %s = {
        kdc = %s
        admin_server = %s
    }

[domain_realm]
    .%s = %s
    %s = %s
""" % (realm, realm, kdc, kdc, realm_lower, realm, realm_lower, realm)
with open("/etc/krb5.conf", "w") as f:
    f.write(krb5)

# Idempotent managed block in /etc/hosts (strip any previous block, then re-append).
BEGIN = "# >>> nestedlab-kerberos >>>"
END = "# <<< nestedlab-kerberos <<<"
with open("/etc/hosts") as f:
    lines = f.read().splitlines()
managed_names = {fqdn for _, fqdn, _ in entries} | {short for _, _, short in entries}
out, skip = [], False
for ln in lines:
    if ln.strip() == BEGIN:
        skip = True
        continue
    if ln.strip() == END:
        skip = False
        continue
    # Remove legacy unmanaged entries for these names as well. Otherwise libc can
    # return the old private 10.10 address before the managed NAT-uplink entry.
    fields = ln.split()
    if not skip and not any(name in managed_names for name in fields[1:]):
        out.append(ln)
block = [BEGIN] + ["%s\t%s %s" % (ip, fqdn, short) for ip, fqdn, short in entries] + [END]
with open("/etc/hosts", "w") as f:
    f.write("\n".join(out + block) + "\n")

print("%s %s" % (realm, kdc))
PY
)"

if [ "$INFO" = "NONE" ] || [ -z "$INFO" ]; then
    echo "[Setup-ControlKerberos] model has no domain; nothing to do."
    exit 0
fi
REALM="${INFO%% *}"
KDC="${INFO##* }"
echo "[Setup-ControlKerberos] realm=$REALM kdc=$KDC; wrote /etc/krb5.conf and /etc/hosts block."

# System packages: krb5-user provides kinit (Ansible auto-kinit needs it on PATH); the
# build toolchain + libkrb5-dev are needed to build pykerberos at pip-install time.
export DEBIAN_FRONTEND=noninteractive
PKGS="krb5-user libkrb5-dev gcc python3-dev"
need=""
for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"; done
if [ -n "$need" ]; then
    # Preseed so krb5-config never blocks on its interactive default-realm prompt.
    echo "krb5-config krb5-config/default_realm string $REALM" | debconf-set-selections
    apt-get update -qq
    apt-get install -y -qq $PKGS
    echo "[Setup-ControlKerberos] installed:$need"
else
    echo "[Setup-ControlKerberos] system packages already present."
fi

# pywinrm kerberos extra (pykerberos builds against the libkrb5-dev installed above).
# Install into the invoking user's site so it lands where Ansible runs (labadmin),
# matching how Invoke-Ansible installs pywinrm[credssp]. Cannot live in Invoke-Ansible's
# deps step: that runs at the first playbook (ping_l0) before this script, when the build
# headers are absent and the pykerberos build would fail. pip install is idempotent.
RUN_USER="${SUDO_USER:-labadmin}"
sudo -u "$RUN_USER" pip3 install --break-system-packages 'pywinrm[kerberos]==0.4.3'
echo "[Setup-ControlKerberos] pywinrm[kerberos] installed for $RUN_USER. done."
