# KeepItClean

**KeepItClean** is a safety-first macOS developer storage cleaner. Its executable is `keep`.

It scans rebuildable caches and developer artifacts, explains risk and rebuild cost, creates an immutable cleanup plan, and moves reviewed files to Trash. It does not run a background agent, require `sudo`, send telemetry, or treat an entire hidden directory as disposable.

> Status: v0.1 development preview. Validate with scan and dry-run before applying any cleanup.

## Why

Developer machines accumulate large but very different kinds of data: Gradle transforms, Kotlin/Native toolchains, LLDB modules, simulator state, container disks, dependency caches, AI-tool sessions, and locally published packages. KeepItClean distinguishes regenerable cache from toolchain, VM, credential, session, database, and user data before it offers an action.

The product is a GPL-3.0 Swift port derived from the safety ideas and history of [Mole](https://github.com/tw93/mole). Its compact storage-review experience also references public [CleanMyMac documentation](https://macpaw.com/support/cleanmymac/knowledgebase/my-tools). KeepItClean is independently named and is not affiliated with MacPaw.

## Requirements

- macOS 14 or newer
- Xcode 16 or a compatible Swift 6 toolchain
- Apple Silicon or Intel Mac

## Build

```bash
swift build
swift test
swift build -c release
swift build -c release --arch arm64 --arch x86_64  # universal binary
```

Install for the current user without `sudo`:

```bash
make install
```

The installer targets `~/.local/bin` by default and refuses to replace an unrelated command named `keep`. Override the prefix with `PREFIX=/custom/prefix make install`.

## Commands

```text
keep
keep scan [--root PATH] [--deep] [--json]
keep analyze [PATH] [--deep] [--json]
keep clean [--plan FILE]
keep clean --apply --trash --plan FILE
keep undo OPERATION_ID
keep finalize OPERATION_ID --confirm TOKEN
keep native-action list [--json]
keep native-action plan ACTION_ID [--json]
keep native-action run --plan FILE --confirm TOKEN [--json]
keep history
keep rules
keep doctor
keep completion SHELL
keep --version
```

`scan`, `analyze`, and `clean` without `--apply --trash` are read-only. The default scan is a fast top-level pass; `--deep` performs bounded recursive measurement for rule-backed candidates before review. `finalize` permanently removes only canonical Trash entries tied to both a reviewed private plan and one KeepItClean operation. Native actions are a separate workflow with an exact argv preview and per-action process gate. Inspection actions remain read-only; state-changing actions are non-undoable and require the generated confirmation token.

The default TUI performs two reviews: a fast inventory selection, then a deep scan of only those exact candidates (or their evidence-bearing parent) before it creates a reviewed plan. Parameterized native action IDs are `colima.stop.<PROFILE>`, `android.avd-delete.<NAME>`, and `vscode.extension-uninstall.<PUBLISHER.NAME>`; use the corresponding read-only list/status action first.

“Read-only” means inspected files are never changed. `scan` and `analyze` do write a private, 30-minute plan under KeepItClean's Application Support directory so the later review/apply boundary is explicit.

## Safety model

1. Scan without mutation.
2. Build a short-lived versioned plan containing canonical path, device, inode, link count, owner, type, allocated/logical/reclaim estimates, modification time, and rule version. Stored plan IDs are create-only and are never overwritten.
3. Review every selected candidate and its exclusion siblings. TUI review derives a new immutable plan ID.
4. Re-run exact rule membership, identity, size, and active-state checks at the mutation boundary.
5. Journal the operation, move user-space files to Trash, and persist each resulting location immediately.
6. Verify outcomes. Undo or explicitly finalize later.

KeepItClean fails closed for symlinks, traversal, protected roots, mount roots, identity/reclaim drift, and data whose ownership or rebuildability cannot be established. Filesystem candidates and state-changing native actions that require inactivity also block on active or unknown owning-tool state. Exact read-only inspections, daemon-native Docker actions, and explicit Gradle/Colima stop actions use narrowly documented per-action policies.

Protected examples include Codex sessions, memories, SQLite databases, credentials and worktree state; Android AVD userdata; Colima disks and volumes; local Maven artifacts; private CocoaPods repositories; and arbitrary Downloads content.

See [SECURITY.md](SECURITY.md) and [docs/SECURITY_DESIGN.md](docs/SECURITY_DESIGN.md).

## Local data

- Short-lived plans: `~/Library/Application Support/KeepItClean/Plans`
- Bounded operation log: `~/Library/Logs/KeepItClean`

KeepItClean has no persistent filesystem scan cache.

## License and upstream

GPL-3.0. See [LICENSE](LICENSE), [UPSTREAM.md](UPSTREAM.md), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
