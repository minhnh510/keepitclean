#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if rg -n '(/bin/(ba)?sh|/usr/bin/sudo|ProcessInfo\.processInfo\.environment\["HOME"\]\s*=)' Sources; then
    echo "Forbidden shell, sudo, or HOME mutation found in production sources." >&2
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

echo "Safety source checks passed."
