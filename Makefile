PREFIX ?= $(HOME)/.local

.PHONY: build test release universal package verify install install-helper uninstall clean

build:
	swift build

test:
	swift test

release:
	swift build -c release

universal:
	swift build -c release --arch arm64 --arch x86_64

package:
	./scripts/package-release.sh

verify: test release
	./scripts/verify-safety.sh

install: release
	PREFIX="$(PREFIX)" ./scripts/install-local.sh

install-helper: release
	./scripts/install-helper.sh

uninstall:
	PREFIX="$(PREFIX)" ./scripts/uninstall-local.sh

clean:
	swift package clean
