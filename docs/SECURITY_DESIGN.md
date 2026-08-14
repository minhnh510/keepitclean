# Security design

## Threat model

KeepItClean treats paths and plans as untrusted input. Relevant failures include path traversal, symlink redirection, hardlink double-counting, sparse-file overstatement, mount-boundary confusion, TOCTOU identity swaps, stale plans, active databases, malicious filenames, and unsafe native-command arguments.

### v0.1 concurrency boundary

v0.1 does not use Foundation pathname mutation or pathname-based scan recursion. Every destructive path component is opened with `openat` plus no-follow flags; scans enumerate held directory descriptors with `fdopendir`/`readdir` and inspect entries with `fstatat`. Lexical normalization and policy preflight still use read-only pathname APIs, but they never authorize a syscall by themselves: apply and undo repeat the boundary with exclusive `renameatx_np` between already-opened parent descriptors, re-check parent bindings, and verify the resulting device/inode before recording success. A deterministic destination is journaled before the first rename, and an advisory lock serializes cooperating `keep` processes.

Finalize first captures the exact recorded Trash entry into a mode-0700 KeepItClean quarantine on the same device. Recursive removal walks held descriptors, rejects owner/device drift, never follows symlinks, and uses `unlinkat` relative to the opened parent. The original Trash pathname is never passed to recursive deletion.

Plan and history state use retained private-directory descriptors as well. Plans are written and `fsync`ed under a private temporary name, published with `renameatx_np(RENAME_EXCL)`, verified by identity, and never overwritten. History publication uses `RENAME_SWAP|RENAME_EXCL` relative to the held directory, verifies both sides of a swap, retires the prior entry, and `fsync`s the directory. Reads compare the opened descriptor with the current no-follow directory entry before accepting decoded state.

Darwin has no public inode-conditional rename or unlink operation. Consequently, fd-relative resolution closes ancestor/path-redirection races and makes a detected leaf mismatch recoverable, but it cannot provide an atomic inode compare-and-swap against a process with write authority over the same namespace. User cleanup remains inside a user-owned Trash/quarantine boundary. The optional System Clean flow is narrower: a separately installed root-owned helper owns its plan, journal, and quarantine, and accepts no arbitrary roots or shell commands. This isolates privileged state from an unprivileged same-user racer, while root/system processes remain part of the platform trust boundary. v0.1.0 is published as a public preview. Its downloadable universal binaries are ad-hoc signed, not Apple-notarized, and accompanied by a SHA-256 checksum; source builds remain the recommended path for stricter Gatekeeper policies.

## Layers

1. **Exact rules:** adapters emit only declared leaves and declare protected siblings.
2. **Canonical validation:** targets must be absolute, user-owned, below an allowed root, and outside protected roots. The sole session-store namespace exception is one exact `~/.codex/sessions/YYYY/MM/DD` directory; current hardcore rule membership, age, identity, and inactive Codex state are still revalidated before mutation. Session files and broader roots remain protected.
3. **Traversal:** scanners walk held directory descriptors, never follow symbolic links, reject directory-entry replacement and mount crossing, and deduplicate physical allocation by device and inode.
4. **Short-lived reviewed plan:** every selected item records identity, ownership, type, timestamps, sizes, rule version, risk, and action kind. Only user-owned plan files inside KeepItClean's private plan store are accepted.
5. **Boundary revalidation:** apply re-runs the exact current rule, process probe, recursive allocation comparison, path policy, and identity checks before action. Unknown rule IDs are rejected.
6. **Recoverability:** filesystem cleanup goes to Trash first. A running journal containing every deterministic Trash destination is written before mutation and updated after each verified move; a failed post-move journal write triggers an identity-checked rollback. On the next undo/finalize request, a still-running Trash APPLY is reconciled under the Trash lock with two stable fd-relative snapshots and becomes terminal only when every reviewed inode is unambiguously at its original or deterministic Trash path.
7. **Permanent boundary:** undo/finalize require a completed or partial journal record to match every selected candidate in its private reviewed plan. Trash names must be canonical immediate children bound to that exact operation ID. Finalize journals its private quarantine destination before capture. Native actions are isolated and previewable, but v0.1 refuses process launch because macOS provides no descriptor-bound `exec` primitive.
8. **Verification:** every outcome is logged as applied, skipped, failed, undone, or finalized. Partial operations remain explicit. Interrupted finalization keeps its pre-journaled quarantine path for manual inspection rather than guessing after an irreversible boundary.
9. **Privileged system caches:** only the root-owned helper may inspect or mutate exact allowlisted system leaves. Plans expire after 15 minutes, confirmation is rechecked inside the helper, apply re-runs rule and identity membership, and files move by fd-relative exclusive rename into `/var/db/KeepItClean/Quarantine`. Final deletion is a separate typed-confirmation command.

## Fail-closed rules

KeepItClean refuses a candidate when ownership, lstat, canonicalization, ancestry, process state, required rule evidence, mount identity, or plan freshness cannot be established. Reference-dependent stores remain report-only until a dedicated adapter can prove their references.

## Test boundary

Mutation tests require a temporary home containing a KeepItClean fixture marker. Privileged-engine tests substitute current-user-owned replicas of the three allowlisted roots and a private state directory inside a separate marker fixture. CI never invokes `sudo`, installs the helper, or touches production system caches.
