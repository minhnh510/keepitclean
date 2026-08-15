#!/bin/bash
set -euo pipefail

INSTALL_PREFIX="${PREFIX:-$HOME/.local}"
TARGET="$INSTALL_PREFIX/bin/keep"

if [[ ! -e "$TARGET" ]]; then
    echo "KeepItClean is not installed at $TARGET"
    exit 0
fi

if [[ ! -x "$TARGET" ]] || ! "$TARGET" --version 2>/dev/null | grep -q '^KeepItClean '; then
    echo "Refusing to remove unrelated command: $TARGET" >&2
    exit 2
fi

rm -f "$TARGET"
echo "Removed KeepItClean: $TARGET"
