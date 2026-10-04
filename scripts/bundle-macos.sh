#!/usr/bin/env bash
# Wraps the macOS release binary into dist/Procmon.app and code-signs it.
#
# Environment:
#   ARCH           arm64 or x86_64, as passed to build-macos.sh (default: host)
#   SIGN_IDENTITY  codesign identity, e.g. "Developer ID Application: …".
#                  Unset: the first Developer ID Application identity in the
#                  keychain, else "-" (ad-hoc, fine for running on this Mac).
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
arch="${ARCH:-$(uname -m)}"
binary="$(swift build --package-path macos -c release --triple "$arch-apple-macosx15.0" \
  --scratch-path "macos/.build/$arch" --show-bin-path)/Procmon"
if [[ -z "${SIGN_IDENTITY+set}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
fi
identity="${SIGN_IDENTITY:--}"
app=dist/Procmon.app

[[ -x "$binary" ]] || { echo "missing $binary — run scripts/build-macos.sh first" >&2; exit 1; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Procmon"
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
