---
type: kb
title: Double NAT for L2 internet access while preserving management
symptom: L2 guests can reach internal services but cannot resolve public DNS or use HTTPS
status: resolved
date: 2026-07-13
updated: 2026-07-13
component: nested-networking
tags:
  - hyper-v
  - nat
  - kerberos
  - winrm
scope: project
context: hyperv-nestlab
---

# 0021 — Double NAT for L2 internet access while preserving management

## Symptom

L2 guests on `10.10.0.0/24` could reach `dc01`, but neither direct public DNS nor HTTPS worked.
The L1 host itself had normal internet access on `10.20.0.0/24`.

## Environment

- L0 CtrlNAT: `10.20.0.0/24`
- L1 LabNAT: `10.10.0.0/24`
- L2 Active Directory DNS: `dc01` at `10.10.0.10`

## Cause

The packet path crosses two private boundaries:

`L2 10.10/24 -> L1 10.20/24 -> L0 -> internet`

The L0 `CtrlNAT` translates only `10.20.0.0/24`. Without a NetNat on L1, packets retain their
`10.10.0.x` source and cannot use the L0 translation. DNS forwarders do not solve this because
both the forwarded DNS packet and later HTTPS traffic still need an outbound route.

## Fix

1. Keep `LabNAT-NAT` on L1 with internal prefix `10.10.0.0/24`. L0 then performs the second NAT.
2. Publish each L2 management endpoint on a deterministic L1 uplink port:
   `15985 + resolved VM index` -> WinRM 5985 or SSH 22.
3. Publish Kerberos KDC TCP/UDP 88 from the L1 uplink to `dc01`.
4. On the control VM, resolve domain L2 FQDNs to the L1 management IP and point MIT Kerberos at
   that same IP. Ansible keeps using each FQDN (therefore the correct HTTP SPN) plus its mapped port.

This preserves transparent outbound internet for every L2 guest and inbound Ansible management
without exposing L2 directly on the physical LAN.

## Validation

- `admin01` kept DNS `10.10.0.10`, resolved `claude.ai`, and reached TCP 443.
- Before static mappings, control-to-L2 Kerberos failed with `Cannot contact any KDC`.
- After KDC and WinRM mappings, `ansible.windows.win_ping` to `admin01` succeeded through port 15987.

## Lessons

- Nested private networks need one translation at each private boundary.
- Outbound NAT removes unsolicited inbound management; publish only the required ports.
- Kerberos can cross a port mapping if the client still connects by the service FQDN and the KDC
  remains reachable.

## Related

- `KB/0003-nested-l2-reachability-router.md`
- `KB/0019-l2-member-winrm-kerberos.md`
