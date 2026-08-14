# KeepItClean Agent Guide

KeepItClean is a macOS 14+ Swift CLI/TUI for reviewing and reclaiming developer storage. Safety is more important than reclaim volume.

## Invariants

- All user-visible file mutations go through the filesystem mutation gateway. Optional System Clean mutations go through the root-owned privileged engine, which reuses the fd-relative filesystem boundary and a root-private journal/quarantine.
- Scans are read-only. `keep clean` remains read-only unless both `--apply` and `--trash` are present.
- Never follow symlinks during traversal or deletion validation.
- Never target `/`, `/System`, `/Applications`, `/Users`, a home directory itself, mount roots, credentials, active databases, or active developer state. `/Library` remains a protected root for normal cleanup; the privileged helper may emit only exact allowlisted regular-file leaves under `/Library/Caches` and `/Library/Logs/DiagnosticReports`, never either root itself. Codex session storage is protected except an exact old `YYYY/MM/DD` bucket authorized by the hardcore retention rule while Codex is proven inactive.
- Unknown ownership, process state, reference state, or path identity fails closed.
- Re-stat device, inode, type, owner, and mtime immediately before a mutation.
- Native actions use an argv allowlist and never interpolate a shell command.
- `sudo` is confined to the CLI privileged-helper client and the explicit helper installer. Never run the user-owned `keep` process as root, never pass a shell string, and never add arbitrary roots to the helper protocol.
- Tests that mutate files must use a marker-guarded temporary home.
- Do not run live cleanup, finalize, undo, or native actions during verification. Live verification is scan and dry-run only.

## Structure

- `KeepItCleanCore`: public models, immutable plans, engine contracts, configuration.
- `KeepItCleanFS`: traversal, allocated-byte accounting, path validation, Trash/history/undo.
- `KeepItCleanRules`: conservative developer-tool adapters and native-action catalog.
- `KeepItCleanTUI`: ANSI/termios renderer and pure interaction state.
- `KeepItCleanSystem`: exact privileged cache rules, 15-minute plans, root-private quarantine, undo, and finalize.
- `KeepItCleanPrivilegedHelper`: fixed root-only command grammar installed explicitly under `/Library/PrivilegedHelperTools`.
- `KeepItCleanCLI`: ArgumentParser command surface named `keep`.

## Verification

Run `swift test` and `swift build -c release`. Destructive behavior is verified only against temporary fixtures. Never invoke `sudo`, install the helper, or scan/mutate live system roots during automated verification. Review every mutation gateway or privileged-engine change line by line.
