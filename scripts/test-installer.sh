#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d -t keepitclean-installer.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

if [[ ! -x "$PROJECT_ROOT/.build/release/keep" ]]; then
    echo "Release binary not found. Run swift build -c release first." >&2
    exit 1
fi
if [[ ! -x "$PROJECT_ROOT/.build/release/keep-privileged-helper" ]]; then
    echo "Release privileged helper not found." >&2
    exit 1
fi
[[ "$("$PROJECT_ROOT/.build/release/keep-privileged-helper" --version)" \
    == "KeepItCleanPrivilegedHelper 0.1.1 protocol-1" ]]
bash -n "$PROJECT_ROOT/scripts/install-helper.sh"
grep -q '^TARGET_PATH="\$TARGET_DIRECTORY/com.minhnh510.keepitclean.helper"$' \
    "$PROJECT_ROOT/scripts/install-helper.sh"
if rg -n '/usr/bin/sudo .*(rm|find|sh|bash)' "$PROJECT_ROOT/scripts/install-helper.sh"; then
    echo "Privileged installer contains an unsafe broad command." >&2
    exit 1
fi

PREFIX="$TEST_ROOT/installed" "$PROJECT_ROOT/scripts/install-local.sh"
[[ "$("$TEST_ROOT/installed/bin/keep" --version)" == "KeepItClean 0.1.1" ]]
PREFIX="$TEST_ROOT/installed" "$PROJECT_ROOT/scripts/uninstall-local.sh"
[[ ! -e "$TEST_ROOT/installed/bin/keep" ]]

mkdir -p "$TEST_ROOT/unrelated/bin"
printf '#!/bin/bash\necho unrelated\n' > "$TEST_ROOT/unrelated/bin/keep"
chmod 0755 "$TEST_ROOT/unrelated/bin/keep"
if PATH="$TEST_ROOT/unrelated/bin:$PATH" PREFIX="$TEST_ROOT/refused" "$PROJECT_ROOT/scripts/install-local.sh"; then
    echo "installer unexpectedly accepted an unrelated keep command" >&2
    exit 1
fi
[[ ! -e "$TEST_ROOT/refused/bin/keep" ]]

echo "Installer ownership checks passed."
