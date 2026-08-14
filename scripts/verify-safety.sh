#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if rg -n '(/bin/(ba)?sh|ProcessInfo\.processInfo\.environment\["HOME"\]\s*=)' Sources; then
    echo "Forbidden shell or HOME mutation found in production sources." >&2
    exit 1
fi

SUDO_HITS="$(rg -n '/usr/bin/sudo' Sources || true)"
if [[ -n "$SUDO_HITS" ]] && echo "$SUDO_HITS" | rg -v '^Sources/KeepItCleanCLI/PrivilegedHelperClient\.swift:'; then
    echo "sudo may appear only in the fixed privileged-helper client." >&2
    exit 1
fi

SPAWN_HITS="$(rg -n 'posix_spawn' Sources || true)"
if [[ -n "$SPAWN_HITS" ]] && echo "$SPAWN_HITS" | rg -v '^Sources/KeepItCleanCLI/PrivilegedHelperClient\.swift:'; then
    echo "Process spawning may appear only in the fixed privileged-helper client." >&2
    exit 1
fi

if rg -n 'FileManager\.default\.(createDirectory|removeItem|moveItem|trashItem)|contentsOfDirectory\(atPath:' Sources; then
    echo "Foundation pathname mutation or pathname-stack traversal found in production sources." >&2
    exit 1
fi

if rg -n 'Process\(|executableURL|\.run\(\)' Sources/KeepItCleanCLI Sources/KeepItCleanFS; then
    echo "Native process launch found inside the CLI/filesystem mutation boundary." >&2
    exit 1
fi

# These flags were added after the Xcode 16.2 / macOS 14 SDK baseline. They are
# redundant here because every *at syscall receives one validated basename and
# an already-opened parent directory descriptor.
if rg -n 'AT_RESOLVE_BENEATH|RENAME_RESOLVE_BENEATH' Sources; then
    echo "Post-macOS-14 resolve-beneath flag found in production sources." >&2
    exit 1
fi

echo "Safety source checks passed."
