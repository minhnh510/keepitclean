# Security policy

KeepItClean performs destructive local operations only after an explicit reviewed plan. Path validation, mutation boundaries, native command execution, and release integrity are security-sensitive.

## Report a vulnerability

Please use GitHub private vulnerability reporting for `minhnh510/keepitclean`. Do not publish an unpatched path-validation, symlink, TOCTOU, privilege, or unintended-deletion issue in a public ticket.

Include the KeepItClean version, macOS version, exact command, plan identifier, reproduction steps, and whether the issue involves a symlink, mount, identity change, Trash, undo, finalize, or native action.

## Security boundaries

- No daemon, privileged helper, `sudo`, shell interpolation, or telemetry.
- Scans never mutate files.
- User-facing mutations pass through one gateway and default to Trash.
- Native actions use a fixed executable plus argv allowlist and are never inferred from filesystem names.
- Unknown reference or ownership state is blocked. Filesystem candidates and native mutations that require an inactive owning tool also block on active or unknown process state.
- Exact read-only inspections bypass activity gates; explicit Gradle/Colima stop actions allow the process they are stopping, and Docker daemon-native actions validate their own exact catalog policy.
- Plans expire after 30 minutes and are bound to the host and file identities observed during scan.
- Permanent finalization is limited to recorded Trash destinations that still match their operation record.

The v0.1 preview detects identity drift at the mutation boundary but does not promise atomic isolation from a malicious concurrent process with the same macOS user ID; see the documented concurrency boundary before enabling mutations.

See [docs/SECURITY_DESIGN.md](docs/SECURITY_DESIGN.md) for the threat model and verification layers.
