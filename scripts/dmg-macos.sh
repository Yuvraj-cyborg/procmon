#!/usr/bin/env bash
# Packs dist/Procmon.app into a compressed, drag-to-install DMG, then signs,
# notarizes and staples it when credentials are available.
#
# Environment:
#   ARCH           suffix for the file name, e.g. arm64 or x86_64 (default: host)
#   SIGN_IDENTITY  codesign identity for the DMG; unset uses the app's own
#                  signature (the one bundle-macos.sh chose), "-" skips signing
#   Notarization, one of:
#     NOTARY_PROFILE  a profile saved with `xcrun notarytool store-credentials`
#     APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID  (API key)
#     APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD  (app-specific password)
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
arch="${ARCH:-$(uname -m)}"
if [[ -z "${SIGN_IDENTITY+set}" ]]; then
  # Sign the DMG with whatever signed the app inside it.
  SIGN_IDENTITY=$(codesign -dvv dist/Procmon.app 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p' | head -1)
fi
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
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${APPLE_API_KEY_ID:-}" ]]; then
    notary_args=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
  elif [[ -n "${APPLE_ID:-}" ]]; then
    notary_args=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
  fi

  if (( ${#notary_args[@]} )); then
    # First submissions for a new Developer ID often sit In Progress well past 30 minutes.
    set +e
    result=$(xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --timeout 2h --output-format json)
    notary_code=$?
    set -e
    echo "$result"
    if [[ "$notary_code" -ne 0 ]]; then
      echo "notarytool exited $notary_code" >&2
      exit "$notary_code"
    fi
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
