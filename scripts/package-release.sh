#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.1}"
ARCHIVE_ROOT="keepitclean-v${VERSION}-macos-universal"
ARCHIVE_NAME="${ARCHIVE_ROOT}.tar.gz"
DIST_DIR="$PROJECT_ROOT/dist"
PRODUCTS_DIR="$PROJECT_ROOT/.build/apple/Products/Release"
KEEP_BINARY="$PRODUCTS_DIR/keep"
HELPER_BINARY="$PRODUCTS_DIR/keep-privileged-helper"
TEMP_ROOT="$(mktemp -d -t keepitclean-release.XXXXXX)"
STAGING="$TEMP_ROOT/$ARCHIVE_ROOT"
trap 'rm -rf "$TEMP_ROOT"' EXIT

cd "$PROJECT_ROOT"
swift build -c release --arch arm64 --arch x86_64

[[ "$($KEEP_BINARY --version)" == "KeepItClean $VERSION" ]]
[[ "$($HELPER_BINARY --version)" == "KeepItCleanPrivilegedHelper $VERSION protocol-1" ]]
/usr/bin/lipo "$KEEP_BINARY" -verify_arch arm64 x86_64
/usr/bin/lipo "$HELPER_BINARY" -verify_arch arm64 x86_64
/usr/bin/codesign --force --sign - --timestamp=none "$KEEP_BINARY"
/usr/bin/codesign --force --sign - --timestamp=none "$HELPER_BINARY"
/usr/bin/codesign --verify --strict "$KEEP_BINARY"
/usr/bin/codesign --verify --strict "$HELPER_BINARY"

mkdir -p \
    "$STAGING/bin" \
    "$STAGING/libexec" \
    "$STAGING/completions" \
    "$STAGING/scripts" \
    "$STAGING/LICENSES" \
    "$DIST_DIR"
install -m 0755 "$KEEP_BINARY" "$STAGING/bin/keep"
install -m 0755 "$HELPER_BINARY" \
    "$STAGING/libexec/com.minhnh510.keepitclean.helper"
install -m 0755 "$PROJECT_ROOT/scripts/install-release.sh" \
    "$STAGING/scripts/install-release.sh"
install -m 0755 "$PROJECT_ROOT/scripts/install-helper.sh" \
    "$STAGING/scripts/install-helper.sh"
install -m 0644 "$PROJECT_ROOT/LICENSE" "$STAGING/LICENSE"
install -m 0644 "$PROJECT_ROOT/README.md" "$STAGING/README.md"
install -m 0644 "$PROJECT_ROOT/CHANGELOG.md" "$STAGING/CHANGELOG.md"
install -m 0644 "$PROJECT_ROOT/UPSTREAM.md" "$STAGING/UPSTREAM.md"
install -m 0644 "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" \
    "$STAGING/THIRD_PARTY_NOTICES.md"
install -m 0644 "$PROJECT_ROOT/.build/checkouts/swift-argument-parser/LICENSE.txt" \
    "$STAGING/LICENSES/swift-argument-parser-LICENSE.txt"

"$KEEP_BINARY" completion zsh > "$STAGING/completions/_keep"
"$KEEP_BINARY" completion bash > "$STAGING/completions/keep.bash"
"$KEEP_BINARY" completion fish > "$STAGING/completions/keep.fish"
chmod 0644 "$STAGING/completions/_keep" \
    "$STAGING/completions/keep.bash" \
    "$STAGING/completions/keep.fish"

rm -f "$DIST_DIR/$ARCHIVE_NAME" "$DIST_DIR/$ARCHIVE_NAME.sha256"
COPYFILE_DISABLE=1 /usr/bin/tar -C "$TEMP_ROOT" -czf "$DIST_DIR/$ARCHIVE_NAME" "$ARCHIVE_ROOT"
cd "$DIST_DIR"
/usr/bin/shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"

echo "Created $DIST_DIR/$ARCHIVE_NAME"
echo "Created $DIST_DIR/$ARCHIVE_NAME.sha256"
