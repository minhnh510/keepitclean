# KeepItClean Agent Guide

KeepItClean is a macOS 14+ Swift CLI/TUI for reviewing and reclaiming developer storage. Safety is more important than reclaim volume.

## Invariants

- All user-visible file mutations go through the filesystem mutation gateway.
- Scans are read-only. `keep clean` remains read-only unless both `--apply` and `--trash` are present.
- Never follow symlinks during traversal or deletion validation.
- Never target `/`, `/System`, `/Library`, `/Applications`, `/Users`, a home directory itself, mount roots, credentials, sessions, active databases, or active developer state.
- Unknown ownership, process state, reference state, or path identity fails closed.
- Re-stat device, inode, type, owner, and mtime immediately before a mutation.
- Native actions use an argv allowlist and never interpolate a shell command.
- Tests that mutate files must use a marker-guarded temporary home.
- Do not run live cleanup, finalize, undo, or native actions during verification. Live verification is scan and dry-run only.

## Structure

- `KeepItCleanCore`: public models, immutable plans, engine contracts, configuration.
- `KeepItCleanFS`: traversal, allocated-byte accounting, path validation, Trash/history/undo.
- `KeepItCleanRules`: conservative developer-tool adapters and native-action catalog.
- `KeepItCleanTUI`: ANSI/termios renderer and pure interaction state.
- `KeepItCleanCLI`: ArgumentParser command surface named `keep`.

## Verification

Run `swift test` and `swift build -c release`. Destructive behavior is verified only against temporary fixtures. Review every mutation gateway change line by line.
