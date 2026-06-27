# 0019 — Configuring a domain member L2 over WinRM needs Kerberos, not NTLM-by-IP

## Symptom

After `Initialize-AdForest` joins `mem01` to `corp.contoso.local`, running Ansible from the
control VM (Ubuntu, **not** domain-joined) to install Windows features on `mem01` fails at the
connection:

```
mem01 | UNREACHABLE! => the specified credentials were rejected by the server
        ... 0x8009030e  (SEC_E_NO_CREDENTIALS)
```

The same control VM reaches the **DC** (`dc01`) fine, and `mem01`'s WinRM is healthy when
poked from inside the domain. So it looks like "mem01 is broken" — it is not.

## Cause

The control VM connected to L2 by **IP + NTLM pass-through**. On a domain **member**, an
inbound NTLM logon with local-style credentials from a non-domain client is rejected
(`SEC_E_NO_CREDENTIALS / 0x8009030e`). It happens to work against the DC and against
freshly-built, not-yet-joined members, which is why the create/cluster paths (which talk to
nodes by IP before they are domain-joined, or with CredSSP) never tripped over it.

Things that look like fixes but are **red herrings** here: `winrm` reset, `LocalAccountTokenFilterPolicy`,
`NtlmMinClientSec`, resetting the machine password. They do not address the real issue —
NTLM-by-IP from a non-domain client to a domain member.

Proof it is a transport problem, not a server fault: `dc01 -> mem01` over **WinRM by FQDN
with Kerberos** succeeds. WinRM on `mem01` is fine; the control VM was just using the wrong
auth path.

## Fix

Talk to domain-joined Windows L2 over **Kerberos by FQDN**, not NTLM by IP.

- `control-node/Setup-ControlKerberos.sh` (run on the control VM as root) writes
  `/etc/krb5.conf` (realm = domain FQDN upper-cased, KDC = DC IP), a managed `/etc/hosts`
  block mapping each domain L2 FQDN -> IP (deterministic name resolution; we do **not**
  depend on the lab DNS from the control segment), installs `krb5-user libkrb5-dev gcc
  python3-dev`, and the `pywinrm[kerberos]` extra. It derives everything from
  `build/resolved.json`, so it is config-driven and idempotent.
- `control-node/Ensure-ControlKerberos.ps1` is the L0 wrapper: it runs only when the model
  declares a domain, pushes the script + model to the control VM, and runs it via sudo.
  `bootstrap.ps1` calls it right **before** `configure_l2.yml` (`bootstrap.ps1:6b`).
- `ansible/inventory/resolved_inventory.py` sets, for each domain-joined **non-cluster**
  Windows L2: `ansible_host = <name>.<domain.fqdn>`, `ansible_winrm_transport = kerberos`,
  `ansible_user = Administrator@<REALM>`, `ansible_password = <lab pw>`. Ansible then
  auto-`kinit`s per host (managed mode, since user is a UPN + password is set).
- `ansible/playbooks/configure_l2.yml` no longer sets `ansible_user`/`ansible_password` in
  play vars. Play vars outrank inventory host vars, so leaving the old `NETBIOS\Administrator`
  override in place would clobber the Kerberos UPN and break `kinit`.

Non-domain Windows L2 (e.g. `minimal-windows`) keep the `group_vars/l2_windows.yml` default
(local `Administrator` + NTLM by IP) — that path is correct for a workgroup box.

### Why cluster nodes are deliberately left on NTLM/CredSSP

`resolved_inventory.py` skips cluster members when applying the Kerberos host vars. S2D needs
a **CredSSP** two-hop delegation (`create_cluster.yml` sets `credssp` in play vars), and that
path already works by IP. Switching it to Kerberos would be an unrelated, risky change.

### Why the kerberos pip extra lives in Setup-ControlKerberos, not Invoke-Ansible

`pywinrm[kerberos]` pulls `pykerberos`, which **compiles** against `libkrb5-dev` at install
time. `Invoke-Ansible.ps1` installs its deps at the very first playbook (`ping_l0`), long
before the build headers exist, so the build would fail there. `Setup-ControlKerberos.sh`
installs the headers first, then the pip extra — and runs only when there is a domain.

## Lessons / general notes

- "Server X is broken" when only **one client/transport** fails is usually an **auth-path**
  problem, not a server fault. Cross-check from a different client (here: DC -> member by
  FQDN/Kerberos) before touching the "broken" host.
- NTLM-by-IP to a **domain member** from a non-domain client is the trap; the DC and unjoined
  members mask it. Domain members want Kerberos (FQDN + ticket).
- Ansible variable precedence bites: **play vars > inventory host vars**. Put per-host
  connection identity in the inventory and keep plays free of `ansible_user`/`ansible_password`
  overrides, or the override silently wins.
- Idempotency stays with the community module (`win_feature`) — the transport change does not
  affect it. Re-running converges to no-change regardless of NTLM vs Kerberos.
