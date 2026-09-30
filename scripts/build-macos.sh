#!/usr/bin/env bash
# Builds the smallest macOS release binary from the Swift package in macos/.
#
# Environment:
#   ARCH  arm64 or x86_64 (default: host)
#
# Output: macos/.build/<arch>/<arch>-apple-macosx/release/Procmon (stripped)
set -euo pipefail
cd "$(dirname "$0")/.."

arch="${ARCH:-$(uname -m)}"
# One scratch folder per architecture: SwiftPM's build plan does not survive
# switching triples in place.
args=(--package-path macos -c release --triple "$arch-apple-macosx15.0" --scratch-path "macos/.build/$arch")

swift build "${args[@]}"
binary="$(swift build "${args[@]}" --show-bin-path)/Procmon"
# The symbol table is only useful to debuggers; the app does not need it.
strip "$binary"
echo "built $binary ($(du -h "$binary" | cut -f1))"
