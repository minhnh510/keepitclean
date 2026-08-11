# Security policy

KeepItClean performs destructive local operations only after an explicit reviewed plan. Path validation, mutation boundaries, native command execution, and release integrity are security-sensitive.

## Report a vulnerability

Please use GitHub private vulnerability reporting for `minhnh510/keepitclean`. Do not publish an unpatched path-validation, symlink, TOCTOU, privilege, or unintended-deletion issue in a public ticket.

Include the KeepItClean version, macOS version, exact command, plan identifier, reproduction steps, and whether the issue involves a symlink, mount, identity change, Trash, undo, finalize, or native action.

## Security boundaries

- No daemon, privileged helper, `sudo`, shell interpolation, or telemetry.
- Scans never mutate files.
- User-facing mutations pass through one gateway and default to Trash.
- Native-action plans use a fixed executable plus argv allowlist and are never inferred from filesystem names. v0.1 does not launch those executables because Darwin lacks descriptor-bound `exec`.
- Unknown reference or ownership state is blocked. Filesystem candidates and native mutations that require an inactive owning tool also block on active or unknown process state.
- Native-action list/plan preserves the exact per-action activity policy for review; production run fails closed before process launch in v0.1.
- Plans expire after 30 minutes and are bound to the host and file identities observed during scan.
- Permanent finalization is limited to recorded Trash destinations that still match their operation record.
- An interrupted Trash APPLY is double-snapshotted under the Trash lock and becomes terminal only when each reviewed inode is unambiguously at its original or deterministic Trash path.

The v0.1 preview uses fd-relative traversal, exclusive fd-relative rename, deterministic pre-journaling, identity verification, and private finalize quarantine. Darwin still has no inode-conditional rename/unlink primitive, so KeepItClean does not promise privilege-style isolation from a malicious concurrent process with the same macOS user ID; see the documented concurrency boundary before enabling mutations.

See [docs/SECURITY_DESIGN.md](docs/SECURITY_DESIGN.md) for the threat model and verification layers.
