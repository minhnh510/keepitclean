#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_PREFIX="${PREFIX:-$HOME/.local}"
INSTALL_DIR="$INSTALL_PREFIX/bin"
TARGET="$INSTALL_DIR/keep"
SOURCE_BINARY="$PROJECT_ROOT/bin/keep"

if [[ ! -x "$SOURCE_BINARY" ]]; then
    echo "Release binary is missing: $SOURCE_BINARY" >&2
    exit 1
fi
if [[ "$($SOURCE_BINARY --version 2>/dev/null)" != "KeepItClean 0.1.0" ]]; then
    echo "Refusing to install a release binary with an unexpected identity." >&2
    exit 1
fi

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

mkdir -p "$INSTALL_DIR"
install -m 0755 "$SOURCE_BINARY" "$TARGET"

mkdir -p \
    "$INSTALL_PREFIX/share/zsh/site-functions" \
    "$INSTALL_PREFIX/share/bash-completion/completions" \
    "$INSTALL_PREFIX/share/fish/vendor_completions.d"
install -m 0644 "$PROJECT_ROOT/completions/_keep" \
    "$INSTALL_PREFIX/share/zsh/site-functions/_keep"
install -m 0644 "$PROJECT_ROOT/completions/keep.bash" \
    "$INSTALL_PREFIX/share/bash-completion/completions/keep"
install -m 0644 "$PROJECT_ROOT/completions/keep.fish" \
    "$INSTALL_PREFIX/share/fish/vendor_completions.d/keep.fish"

echo "Installed KeepItClean: $TARGET"
echo "Installed zsh, bash, and fish completions under $INSTALL_PREFIX/share"
