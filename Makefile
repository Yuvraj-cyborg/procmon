# Short commands for building and packaging Procmon.
# Run inside `nix develop` to get the pinned toolchain and tools, or use a
# local Rust toolchain directly.

VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
TARGET  ?= $(shell rustc -vV | sed -n 's/^host: //p')
BINARY  := target/$(TARGET)/release/procmon
export TARGET

.PHONY: build run test app install dmg linux icon size clean

build: ## Smallest release binary (pinned nightly when rustup is available)
	./scripts/build-release.sh

run: ## Debug build, launched
	cargo run

test:
	cargo test

app: build ## dist/Procmon.app (ad-hoc signed unless SIGN_IDENTITY is set)
	./scripts/bundle-macos.sh

install: app ## Copy Procmon.app into /Applications
	rm -rf /Applications/Procmon.app
	cp -R dist/Procmon.app /Applications/Procmon.app
	@echo "installed /Applications/Procmon.app"

dmg: app ## dist/Procmon-<version>-macos-<arch>.dmg
	./scripts/dmg-macos.sh

linux: build ## dist/procmon-<version>-linux-<arch>.tar.gz
	./scripts/package-linux.sh

icon: ## Regenerate assets/icon from scripts/icon/generate.mjs (needs node + resvg)
	./scripts/icon/build.sh

size: build ## Report binary size
	@ls -lh $(BINARY) | awk '{print "procmon $(VERSION):", $$5}'

clean:
	cargo clean
	rm -rf dist
