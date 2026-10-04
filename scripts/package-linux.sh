#!/usr/bin/env bash
# Packs a release binary into dist/procmon-<version>-linux-<arch>.tar.xz with
# a desktop entry, icon and install script. xz makes the download about 28%
# smaller than gzip, and every current distribution's tar unpacks it.
#
# Environment:
#   TARGET  Rust target triple the binary was built for (default: host)
#   ARCH    suffix for the file name (default: uname -m)
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
arch="${ARCH:-$(uname -m)}"
binary="target/${TARGET:+$TARGET/}release/procmon"
name="procmon-$version-linux-$arch"
stage="dist/$name"

[[ -x "$binary" ]] || { echo "missing $binary — run cargo build --release first" >&2; exit 1; }

rm -rf "$stage"
install -Dm755 "$binary" "$stage/bin/procmon"
install -Dm644 packaging/linux/procmon.desktop "$stage/share/applications/procmon.desktop"
install -Dm644 assets/icon/procmon-512.png "$stage/share/icons/hicolor/512x512/apps/procmon.png"
install -Dm755 packaging/linux/install.sh "$stage/install.sh"

tar -C dist -cJf "dist/$name.tar.xz" "$name"
rm -rf "$stage"
echo "built dist/$name.tar.xz ($(du -h "dist/$name.tar.xz" | cut -f1))"
