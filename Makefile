# Short commands for building and packaging Procmon.
#
# macOS: the native Swift app in macos/ (needs Xcode 26 or newer).
# Linux and Windows: the Rust app in the repository root. Run inside
# `nix develop` to get the pinned toolchain, or use a local Rust toolchain.

VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
TARGET  ?= $(shell rustc -vV 2>/dev/null | sed -n 's/^host: //p')
export TARGET

.PHONY: build run test app install dmg rust rust-run rust-test linux size clean

ifeq ($(shell uname -s),Darwin)
build: ## Smallest macOS binary
	./scripts/build-macos.sh

run: ## macOS app, debug build
	swift run --package-path macos

test:
	swift test --package-path macos

size: build ## Report binary size
	@ls -lh macos/.build/$(shell uname -m)/$(shell uname -m)-apple-macosx/release/Procmon | awk '{print "Procmon $(VERSION):", $$5}'
else
build: rust

run: rust-run

test: rust-test

size: rust ## Report binary size
	@ls -lh target/$(TARGET)/release/procmon | awk '{print "procmon $(VERSION):", $$5}'
endif

app: ## dist/Procmon.app (ad-hoc signed unless SIGN_IDENTITY is set)
	./scripts/build-macos.sh
	./scripts/bundle-macos.sh

install: app ## Copy Procmon.app into /Applications
	rm -rf /Applications/Procmon.app
	cp -R dist/Procmon.app /Applications/Procmon.app
	@echo "installed /Applications/Procmon.app"

dmg: app ## dist/Procmon-<version>-macos-<arch>.dmg
	./scripts/dmg-macos.sh

rust: ## Smallest Rust release binary (pinned nightly when rustup is available)
	./scripts/build-release.sh

rust-run: ## Rust app, debug build
	cargo run

rust-test:
	cargo test

linux: rust ## dist/procmon-<version>-linux-<arch>.tar.gz
	./scripts/package-linux.sh

clean:
	cargo clean
	rm -rf dist macos/.build
