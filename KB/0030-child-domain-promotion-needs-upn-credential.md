# 0030 — Child-domain promotion from a workgroup host needs a DNS-qualified credential

## Symptom

`Install-ADDSDomain` fails while creating a child domain even though the parent DC is reachable and the parent domain's A and SRV records resolve:

```text
Verification of user credential permissions failed. Specify a DNS-resolvable
name for the domain to which this user account belongs.
```

The credential was expressed as `CORP\Administrator`.

## Cause

The machine being promoted is still in a workgroup. During the prerequisite check, `Install-ADDSDomain` validates the credential's domain through DNS. A NetBIOS-qualified identity does not carry the DNS domain needed by this check, so validation can fail before promotion.

## Fix

Use a UPN tied to the parent DNS domain:

```powershell
$credential = New-Object System.Management.Automation.PSCredential(
    "Administrator@$ParentDomain",
    (ConvertTo-SecureString $Password -AsPlainText -Force))
```

`Add-LabChildDomainController.ps1` uses this form for `Install-ADDSDomain`.

## Lesson

Connectivity, SRV resolution, and credential qualification are separate checks. Do not interpret this message as a DNS outage until the same parent account has also been tried as a UPN.
