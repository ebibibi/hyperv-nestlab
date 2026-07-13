---
type: kb
title: L1 OS disk declaration is ignored for cloned golden images
symptom: The L1 C drive remains 40 GB and nearly fills even when l1.disk_gb declares a larger size
status: resolved
date: 2026-07-13
updated: 2026-07-13
component: l1-provisioning
tags:
  - hyper-v
  - vhdx
  - idempotence
  - powershell-direct
scope: project
context: hyperv-nestlab
---

# 0022 — L1 OS disk declaration is ignored for cloned golden images

## Symptom

`nested-lab-01` had a 39.7 GB C: volume with only about 1 GB free, although
`l1/standard-host.yml` declared a larger `l1.disk_gb` value.

## Environment

- L0 Hyper-V host running a Gen2 L1 VM
- 40 GB Windows Server golden VHDX used as the L1 base image
- Dynamically expanding VHDX attached through the Gen2 SCSI controller

## Cause

`Ensure-LabVm` copied the 40 GB golden VHDX and used `DiskGB` only when creating a blank VHDX.
It also reconciled CPU, memory, and nested-virtualization drift for existing VMs, but not disk-size
drift. Therefore the model value was accepted and passed through without changing the VHDX or the
guest partition.

## Fix

1. In `scripts/HyperVLab.psm1.ps1`, compare the attached OS VHDX maximum size with `DiskGB` and
   call `Resize-VHD` only when the declared value is larger. Never shrink an existing disk.
2. In `scripts/Initialize-L1Network.ps1`, use PowerShell Direct to extend C: to
   `Get-PartitionSupportedSize().SizeMax` when more than 64 MB remains unallocated.
3. Set the standard L1 declaration to 160 GB in `l1/standard-host.yml`.
4. Run provisioning twice: the first run expands the disk and partition; the second is no-change.

## Lessons

- Copying a dynamic VHDX preserves its virtual maximum size; dynamic allocation does not make its
  maximum size follow the destination VM declaration.
- Declarative configuration must reconcile existing resources, not only creation-time values.
- VHDX expansion and guest partition expansion are separate operations and both must converge.
- Expansion may be automatic, but shrinking should require an explicit migration procedure.

## Related

- `KB/0009-control-vm-rootfs-resize.md`
- `KB/0018-resize-existing-vm-resources.md`
