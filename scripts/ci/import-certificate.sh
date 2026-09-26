#!/usr/bin/env bash
# Imports the Developer ID certificate from CI secrets into a throwaway
# keychain and prints the identity to $GITHUB_OUTPUT. Without secrets it
# falls back to ad-hoc signing ("-") so unsigned builds still work.
#
# Environment:
#   APPLE_CERTIFICATE_P12       base64 of the exported .p12
#   APPLE_CERTIFICATE_PASSWORD  password chosen when exporting it
#   APPLE_SIGNING_IDENTITY      optional; defaults to the first Developer ID found
set -euo pipefail

output="${GITHUB_OUTPUT:-/dev/stdout}"

if [[ -z "${APPLE_CERTIFICATE_P12:-}" ]]; then
  echo "No signing certificate configured; using ad-hoc signing." >&2
  echo "identity=-" >> "$output"
  exit 0
fi

keychain="$RUNNER_TEMP/signing.keychain-db"
keychain_password=$(openssl rand -hex 24)
certificate="$RUNNER_TEMP/certificate.p12"

printf '%s' "$APPLE_CERTIFICATE_P12" | base64 --decode > "$certificate"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
rm -f "$certificate"

identity="${APPLE_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning "$keychain" \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
fi
[[ -n "$identity" ]] || { echo "No Developer ID Application identity in the certificate" >&2; exit 1; }

echo "Signing as: $identity" >&2
echo "identity=$identity" >> "$output"
