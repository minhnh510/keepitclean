#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if rg -n '(/bin/(ba)?sh|/usr/bin/sudo|ProcessInfo\.processInfo\.environment\["HOME"\]\s*=)' Sources; then
    echo "Forbidden shell, sudo, or HOME mutation found in production sources." >&2
    exit 1
fi

if rg -n 'FileManager\.default\.removeItem' Sources --glob '!**/MutationGateway.swift'; then
    echo "Direct FileManager.removeItem must stay inside MutationGateway.swift." >&2
    exit 1
fi

echo "Safety source checks passed."
