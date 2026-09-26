#!/usr/bin/env bash
# Packs dist/Procmon.app into a compressed, drag-to-install DMG, then signs,
# notarizes and staples it when credentials are available.
#
# Environment:
#   ARCH           suffix for the file name, e.g. arm64 or x86_64 (default: host)
#   SIGN_IDENTITY  codesign identity for the DMG (skipped when unset or "-")
#   Notarization, either an App Store Connect API key:
#     APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
#   or an Apple ID with an app-specific password:
#     APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
arch="${ARCH:-$(uname -m)}"
identity="${SIGN_IDENTITY:--}"
dmg="dist/Procmon-$version-macos-$arch.dmg"

[[ -d dist/Procmon.app ]] || { echo "missing dist/Procmon.app — run scripts/bundle-macos.sh" >&2; exit 1; }

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R dist/Procmon.app "$staging/"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
# ULMO (LZMA) gives the smallest images; supported since macOS 10.15.
hdiutil create -quiet -volname Procmon -srcfolder "$staging" -fs HFS+ -format ULMO "$dmg"

if [[ "$identity" != "-" ]]; then
  codesign --force --sign "$identity" --timestamp "$dmg"

  notary_args=()
  if [[ -n "${APPLE_API_KEY_ID:-}" ]]; then
    notary_args=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
  elif [[ -n "${APPLE_ID:-}" ]]; then
    notary_args=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
  fi

  if (( ${#notary_args[@]} )); then
    result=$(xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --timeout 30m --output-format json)
    echo "$result"
    status=$(plutil -extract status raw -o - - <<< "$result")
    if [[ "$status" != "Accepted" ]]; then
      xcrun notarytool log "$(plutil -extract id raw -o - - <<< "$result")" "${notary_args[@]}" >&2
      echo "notarization finished with status: $status" >&2
      exit 1
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
  else
    echo "no notarization credentials set; the DMG is signed but not notarized" >&2
  fi
fi

echo "built $dmg ($(du -h "$dmg" | cut -f1))"
