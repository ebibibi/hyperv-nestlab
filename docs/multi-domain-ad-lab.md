# Multi-domain Active Directory lab

The base `l2/ad-forest.yml` topology creates the forest root. The following incremental commands expand a running lab into a single forest with two domains and two controllers per domain.

```powershell
# Forest root replicas
pwsh -File .\scripts\Add-LabDomainController.ps1 `
  -Name dc02 -IPAddress 10.10.0.11

# First controller of branch.corp.contoso.local
pwsh -File .\scripts\Add-LabChildDomainController.ps1 `
  -Name brdc01 -IPAddress 10.10.0.12 `
  -ParentDcIp 10.10.0.10 `
  -ParentDomainFqdn corp.contoso.local -ParentNetBIOS CORP `
  -ChildLabel branch -ChildNetBIOS BRANCH

# Replica in the child domain
pwsh -File .\scripts\Add-LabDomainController.ps1 `
  -Name brdc02 -IPAddress 10.10.0.13 -ExistingDcIp 10.10.0.12 `
  -DomainFqdn branch.corp.contoso.local -NetBIOS BRANCH
```

All added controllers use dynamic memory by default. A practical minimum for L1 is 40 GB when other 8 GB member VMs are running.

## Validation

Run from a forest-root controller:

```powershell
Get-ADForest | Select-Object -ExpandProperty Domains
Get-ADDomainController -Filter * -Server corp.contoso.local
Get-ADDomainController -Filter * -Server branch.corp.contoso.local
repadmin /replsummary
repadmin /showrepl * /csv
```

Expected forest domains:

- `corp.contoso.local`
- `branch.corp.contoso.local`

Expected controllers:

- Forest root: `dc01`, `dc02`
- Child domain: `brdc01`, `brdc02`

## Idempotency

Both provisioning scripts inspect the final domain role before attempting local Administrator sign-in. Re-running them against an already promoted controller does not promote it again; it converges the parent DNS delegation, converts any temporary file-backed child zone to domain-replicated AD integration, and verifies ADWS and the domain role before returning.

## Safety

These scripts only target L2 VMs inside `nested-lab-01`. They do not operate on the L0 production VMs (`moviegen` or `selfhost`). Use `teardown.ps1` only with the repository safeguards and never target an arbitrary VM name.
