# Security design

## Threat model

KeepItClean treats paths and plans as untrusted input. Relevant failures include path traversal, symlink redirection, hardlink double-counting, sparse-file overstatement, mount-boundary confusion, TOCTOU identity swaps, stale plans, active databases, malicious filenames, and unsafe native-command arguments.

### v0.1 concurrency boundary

v0.1 re-stats identity immediately before each Foundation filesystem call and fails closed on every drift it can observe. macOS `FileManager.trashItem`, `moveItem`, and recursive `removeItem` accept paths rather than open file descriptors, so v0.1 does not claim atomic protection against a deliberately racing process running as the same user between the last `lstat` and the Foundation call. Such a process already has the user's filesystem authority. Closing that final window requires fd-relative quarantine/recovery plus a future mutation journal; until then KeepItClean remains a development preview and no release artifact is published.

## Layers

1. **Exact rules:** adapters emit only declared leaves and declare protected siblings.
2. **Canonical validation:** targets must be absolute, user-owned, below an allowed root, and outside protected roots.
3. **Traversal:** scanners never follow symbolic links and deduplicate physical allocation by device and inode.
4. **Short-lived reviewed plan:** every selected item records identity, ownership, type, timestamps, sizes, rule version, risk, and action kind. Only user-owned plan files inside KeepItClean's private plan store are accepted.
5. **Boundary revalidation:** apply re-runs the exact current rule, process probe, recursive allocation comparison, path policy, and identity checks before action. Unknown rule IDs are rejected.
6. **Recoverability:** filesystem cleanup goes to Trash first. A running journal is written before mutation and updated with each resulting Trash path; a failed post-move journal write triggers rollback.
7. **Permanent boundary:** undo/finalize require a completed or partial journal record to match every selected candidate in its private reviewed plan. Trash paths must be canonical entries under an eligible Trash root; native actions are isolated, previewed, process-gated, pre-journaled, and confirmed separately.
8. **Verification:** every outcome is logged as applied, skipped, failed, undone, or finalized. Partial operations remain explicit.

## Fail-closed rules

KeepItClean refuses a candidate when ownership, lstat, canonicalization, ancestry, process state, required rule evidence, mount identity, or plan freshness cannot be established. Reference-dependent stores remain report-only until a dedicated adapter can prove their references.

## Test boundary

Mutation tests require a temporary home containing a KeepItClean fixture marker. Production home paths are not accepted by the test mutation gateway.
