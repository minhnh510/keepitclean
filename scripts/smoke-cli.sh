#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEP_BINARY="$PROJECT_ROOT/.build/release/keep"

if [[ ! -x "$KEEP_BINARY" ]]; then
    echo "Release binary not found: $KEEP_BINARY" >&2
    exit 1
fi

[[ "$($KEEP_BINARY --version)" == "KeepItClean 0.1.0" ]]
"$KEEP_BINARY" --help | grep -q 'scan'
"$KEEP_BINARY" --help | grep -q 'Dashboard Clean combines normal, hardcore'
"$KEEP_BINARY" --hardcore --help | grep -q -- '--interactive'
"$KEEP_BINARY" native-action --help | grep -q 'native-action'
"$KEEP_BINARY" system --help | grep -q 'Root-owned system-cache cleanup'
"$KEEP_BINARY" system scan --help | grep -q 'never mutates files'
"$PROJECT_ROOT/.build/release/keep-privileged-helper" --version \
    | grep -q '^KeepItCleanPrivilegedHelper 0.1.0 protocol-1$'
"$KEEP_BINARY" scan --help | grep -q -- '--hardcore'
"$KEEP_BINARY" clean --help | grep -q -- '--hardcore'
"$KEEP_BINARY" clean --help | grep -q -- '--interactive'

if "$KEEP_BINARY" scan --apply >/dev/null 2>&1; then
    echo "scan unexpectedly accepted a mutation flag" >&2
    exit 1
fi
if "$KEEP_BINARY" analyze --trash >/dev/null 2>&1; then
    echo "analyze unexpectedly accepted a mutation flag" >&2
    exit 1
fi

ZSH_COMPLETION="$(mktemp -t keepitclean-zsh.XXXXXX)"
BASH_COMPLETION="$(mktemp -t keepitclean-bash.XXXXXX)"
FISH_COMPLETION="$(mktemp -t keepitclean-fish.XXXXXX)"
trap 'rm -f "$ZSH_COMPLETION" "$BASH_COMPLETION" "$FISH_COMPLETION"' EXIT

"$KEEP_BINARY" completion zsh > "$ZSH_COMPLETION"
"$KEEP_BINARY" completion bash > "$BASH_COMPLETION"
"$KEEP_BINARY" completion fish > "$FISH_COMPLETION"
zsh -n "$ZSH_COMPLETION"
bash -n "$BASH_COMPLETION"
grep -Eq "complete -c '?keep'?" "$FISH_COMPLETION"

echo "CLI smoke checks passed."
