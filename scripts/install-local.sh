#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_PREFIX="${PREFIX:-$HOME/.local}"
INSTALL_DIR="$INSTALL_PREFIX/bin"
TARGET="$INSTALL_DIR/keep"
BUILT_BINARY="$PROJECT_ROOT/.build/release/keep"

EXISTING_KEEP="$(command -v keep 2>/dev/null || true)"
if [[ -n "$EXISTING_KEEP" ]]; then
    if [[ ! -x "$EXISTING_KEEP" ]] || ! "$EXISTING_KEEP" --version 2>/dev/null | grep -q '^KeepItClean '; then
        echo "Refusing to install while an unrelated keep command exists: $EXISTING_KEEP" >&2
        exit 2
    fi
fi

if [[ -e "$TARGET" ]]; then
    if [[ ! -x "$TARGET" ]] || ! "$TARGET" --version 2>/dev/null | grep -q '^KeepItClean '; then
        echo "Refusing to overwrite unrelated command: $TARGET" >&2
        exit 2
    fi
fi

if [[ ! -x "$BUILT_BINARY" ]]; then
    echo "Release binary not found. Run: swift build -c release" >&2
    exit 3
fi

mkdir -p "$INSTALL_DIR"
install -m 0755 "$BUILT_BINARY" "$TARGET"
echo "Installed KeepItClean: $TARGET"
