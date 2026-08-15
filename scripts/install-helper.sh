#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLED_BINARY="$PROJECT_ROOT/libexec/com.minhnh510.keepitclean.helper"
if [[ -n "${KEEPITCLEAN_HELPER_BINARY:-}" ]]; then
    SOURCE_BINARY="$KEEPITCLEAN_HELPER_BINARY"
elif [[ -x "$BUNDLED_BINARY" ]]; then
    SOURCE_BINARY="$BUNDLED_BINARY"
else
    SOURCE_BINARY="$PROJECT_ROOT/.build/release/keep-privileged-helper"
fi
TARGET_DIRECTORY="/Library/PrivilegedHelperTools"
TARGET_PATH="$TARGET_DIRECTORY/com.minhnh510.keepitclean.helper"
EXPECTED_IDENTITY="KeepItCleanPrivilegedHelper 0.1.1 protocol-1"

if [[ ! -x "$SOURCE_BINARY" ]]; then
    echo "Missing release helper: $SOURCE_BINARY" >&2
    echo "Run: swift build -c release" >&2
    exit 1
fi

if [[ "$($SOURCE_BINARY --version)" != "$EXPECTED_IDENTITY" ]]; then
    echo "Refusing to install a helper with an unexpected identity." >&2
    exit 1
fi

if [[ -e "$TARGET_PATH" ]]; then
    EXISTING_OWNER="$(/usr/bin/stat -f '%u' "$TARGET_PATH")"
    EXISTING_MODE="$(/usr/bin/stat -f '%Sp' "$TARGET_PATH")"
    if [[ -L "$TARGET_PATH" || "$EXISTING_OWNER" != "0" \
        || "${EXISTING_MODE:0:1}" != "-" \
        || "${EXISTING_MODE:5:1}" == "w" \
        || "${EXISTING_MODE:8:1}" == "w" ]]; then
        echo "Refusing to replace an unsafe existing helper at $TARGET_PATH" >&2
        exit 1
    fi
    if [[ "$($TARGET_PATH --version 2>/dev/null || true)" != "$EXPECTED_IDENTITY" ]]; then
        echo "Refusing to replace a binary that is not KeepItClean's helper." >&2
        exit 1
    fi
fi

SOURCE_SHA="$(/usr/bin/shasum -a 256 "$SOURCE_BINARY" | /usr/bin/awk '{print $1}')"
echo "Installing the audited KeepItClean helper at $TARGET_PATH"
echo "macOS will request administrator access for this one fixed destination."
/usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 "$TARGET_DIRECTORY"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 "$SOURCE_BINARY" "$TARGET_PATH"

INSTALLED_OWNER="$(/usr/bin/stat -f '%u' "$TARGET_PATH")"
INSTALLED_MODE="$(/usr/bin/stat -f '%Sp' "$TARGET_PATH")"
INSTALLED_SHA="$(/usr/bin/shasum -a 256 "$TARGET_PATH" | /usr/bin/awk '{print $1}')"
if [[ -L "$TARGET_PATH" || "$INSTALLED_OWNER" != "0" \
    || "${INSTALLED_MODE:0:1}" != "-" \
    || "${INSTALLED_MODE:5:1}" == "w" \
    || "${INSTALLED_MODE:8:1}" == "w" \
    || "$INSTALLED_SHA" != "$SOURCE_SHA" ]]; then
    echo "Installed helper verification failed." >&2
    exit 1
fi

echo "Installed and verified: $TARGET_PATH"
echo "Preview only: keep system scan"
