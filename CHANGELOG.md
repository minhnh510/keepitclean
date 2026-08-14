# Changelog

## 0.1.0 - 2026-08-14

First public preview of KeepItClean.

- Swift 6 CLI/TUI for macOS 14+ on Apple Silicon and Intel.
- One all-in-one Clean review for normal, hardcore-retention, and optional system cleanup.
- Trash-first developer cleanup with immutable plans, operation journals, undo, and explicit finalize.
- fd-relative, no-follow traversal and mutation boundaries with identity revalidation and crash recovery.
- Conservative rules for Gradle, Android/NDK, Kotlin/Native, LLDB, CocoaPods, Maven, VS Code, generated project artifacts, and protected Codex state.
- Seven-day Gradle transform retention and reference-aware toolchain retention.
- Optional root-owned helper for a fixed allowlist of old system cache/log leaves, using protected quarantine and separate undo/finalize.
- JSON output, shell completions, doctor/history/rules commands, universal release archive, and SHA-256 checksum.

The downloadable binaries are ad-hoc signed and not Apple-notarized. Native-action execution remains disabled in v0.1.0 because macOS does not provide descriptor-bound execution for user-installed tools.
