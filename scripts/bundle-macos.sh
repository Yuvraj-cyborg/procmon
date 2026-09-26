#!/usr/bin/env bash
# Wraps a release binary into dist/Procmon.app and code-signs it.
#
# Environment:
#   TARGET         Rust target triple the binary was built for (default: host)
#   SIGN_IDENTITY  codesign identity, e.g. "Developer ID Application: …"
#                  (default "-": ad-hoc, fine for running on this Mac)
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
binary="target/${TARGET:+$TARGET/}release/procmon"
identity="${SIGN_IDENTITY:--}"
app=dist/Procmon.app

[[ -x "$binary" ]] || { echo "missing $binary — run cargo build --release first" >&2; exit 1; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/procmon"
cp assets/icon/Procmon.icns "$app/Contents/Resources/Procmon.icns"
sed "s/@VERSION@/$version/g" packaging/macos/Info.plist > "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

sign_args=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  # Notarization requires the hardened runtime and a secure timestamp.
  sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --strict --verbose=1 "$app"

echo "built $app ($version, $(du -sh "$app" | cut -f1), signed with: $identity)"
