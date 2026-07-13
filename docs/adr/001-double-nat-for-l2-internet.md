---
type: adr
id: ADR-001
title: Use double NAT for transparent L2 internet access
decision: Use L1 and L0 NAT stages, with explicit inbound KDC and per-VM management mappings on L1.
status: accepted
date: 2026-07-13
deciders: [Masahiko Ebita, Codex]
tags: [networking, hyper-v, nat, kerberos]
scope: context
context: hyperv-nestlab
supersedes:
superseded_by:
---

# Use double NAT for transparent L2 internet access

## Context

L2 guests use the private `10.10.0.0/24` network behind the nested L1 Hyper-V host. L1 reaches
L0 through the private `10.20.0.0/24` control network, and L0 provides the final internet NAT.

Pure routing kept control-node-to-L2 management simple, but L0 translated only `10.20.0.0/24`.
Packets originating from `10.10.0.0/24` therefore could not reach public DNS or HTTPS. This
prevented normal package installation and made L2 behavior unlike a typical server environment.

## Decision

Use two outbound NAT stages:

1. L1 translates L2 traffic from `10.10.0.0/24` to its `10.20.0.20` uplink.
2. L0 translates `10.20.0.0/24` traffic to the physical network and internet.

Because L1 NAT blocks unsolicited inbound connections, publish only the management endpoints
required by automation:

- one deterministic L1 uplink port per L2 VM, mapped to WinRM 5985 or SSH 22;
- Kerberos KDC TCP and UDP 88, mapped to the domain controller.

The control VM resolves domain L2 FQDNs to the L1 uplink and uses each VM's mapped port. Keeping
the FQDN preserves the correct Kerberos HTTP service principal.

## Alternatives considered

### Pure routing without L1 NAT

Rejected because all L2 guests retained `10.10.0.x` source addresses at L0 and had no transparent
internet access.

### Application-specific HTTP proxy

Rejected because it would solve only selected installers, require proxy-aware configuration, and
would not make internet behavior natural for every L2 VM.

### Direct L1 NAT without inbound mappings

Rejected because it provided outbound internet but made the control VM unable to contact the KDC
or manage L2 guests over WinRM/SSH.

## Rationale

Double NAT matches the actual two-boundary topology and gives every guest conventional outbound
connectivity. Narrow static mappings retain automated management without exposing the L2 subnet
to the physical LAN or weakening the AD DNS design.

## Consequences

- All L2 VMs can use public DNS indirectly through AD DNS and can establish outbound HTTPS.
- The control plane depends on deterministic management-port allocation and KDC mappings.
- Adding or reordering VMs changes derived port assignments; the resolver and setup playbook
  converge mappings together, so the resolved model remains the source of truth.
- RDP from inside L1 continues to use private L2 addresses directly.

## Related

- [KB 0021: Double NAT for L2 internet access while preserving management](../../KB/0021-l2-double-nat-management.md)
- [Access guide](../access-guide.md)
- [Issue #16](https://github.com/ebibibi/hyperv-nestlab/issues/16)
- [PR #17](https://github.com/ebibibi/hyperv-nestlab/pull/17)
