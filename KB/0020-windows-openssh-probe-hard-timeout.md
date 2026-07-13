# 0020 — A Windows OpenSSH readiness probe needs a hard per-process timeout

## Symptom

`bootstrap.ps1` stopped at the control VM readiness message even though all independent checks
showed that the VM was healthy:

- `10.20.0.10` replied to ping.
- Manual SSH returned immediately.
- `/home/labadmin/ansible-ready.txt` existed.
- `cloud-init status --long` reported `done`.

The configured 600-second readiness timeout never fired. The host still had an `ssh.exe` child
running the trivial marker command long after that command should have completed.

## Cause

The timeout guarded the **outer PowerShell loop**, while the loop synchronously invoked
`ssh.exe`. If one Windows OpenSSH process remained alive after connecting, PowerShell never
returned to the loop and therefore never evaluated the stopwatch again.

`ConnectTimeout=5` did not help because it only limits connection establishment. SSH keepalives
also detect a dead server connection, but they do not guarantee that a connected remote command
will exit within a fixed wall-clock time.

## Fix

`control-node/Ensure-ControlNode.ps1` now applies two layers of protection:

1. Non-interactive SSH options (`BatchMode=yes` and bounded server keepalives).
2. A .NET `Process` wrapper with a hard 15-second `WaitForExit` deadline. When exceeded, it calls
   `Kill(true)` to remove the entire stuck process tree and lets the outer readiness loop retry.
3. No redirected SSH output streams. The remote command uses `test -s` and readiness is determined
   only from the process exit code, avoiding an EOF wait after `ssh.exe` has exited.
4. The subsequent Ansible self-test uses the same bounded process helper. Leaving even one direct
   `& ssh ... 2>&1` call in this path can reintroduce the hang after readiness succeeds.

A static regression test in `tests/test_control_node_scripts.py` ensures these safeguards remain.

## Lessons / general notes

- A timeout around a loop is ineffective when a synchronous child call inside the loop can block
  forever.
- Bound both levels: the individual process execution and the overall retry window.
- `ConnectTimeout` is not a command timeout.
- Avoid `ReadToEnd()` in a readiness probe when the exit code can express the complete result.
- On cancellation, confirm that remote-shell child processes actually terminated; interrupting the
  client-side SSH session does not always clean up Windows-hosted descendants.
