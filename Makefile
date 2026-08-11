PREFIX ?= $(HOME)/.local

.PHONY: build test release universal verify install uninstall clean

build:
	swift build

test:
	swift test

release:
	swift build -c release

universal:
	swift build -c release --arch arm64 --arch x86_64

verify: test release
	./scripts/verify-safety.sh

install: release
	PREFIX="$(PREFIX)" ./scripts/install-local.sh

uninstall:
	PREFIX="$(PREFIX)" ./scripts/uninstall-local.sh

clean:
	swift package clean
