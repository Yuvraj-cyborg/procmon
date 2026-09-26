#!/usr/bin/env bash
# Stores the macOS signing and notarization credentials as GitHub Actions
# secrets for this repository. Run it locally; nothing is written to disk.
#
# Usage: scripts/ci/set-github-secrets.sh <developer-id-application.p12>
#
# Export the .p12 from Keychain Access: right-click your
# "Developer ID Application: …" certificate (with its private key) → Export.
set -euo pipefail

p12="${1:?usage: set-github-secrets.sh <developer-id-application.p12>}"
[[ -f "$p12" ]] || { echo "no such file: $p12" >&2; exit 1; }
command -v gh > /dev/null || { echo "needs the GitHub CLI (gh)" >&2; exit 1; }

read -rsp "Password you set when exporting $p12: " p12_password
echo
base64 -i "$p12" | gh secret set APPLE_CERTIFICATE_P12
gh secret set APPLE_CERTIFICATE_PASSWORD --body "$p12_password"

echo
echo "Notarization credentials:"
echo "  1) App Store Connect API key (recommended for CI)"
echo "  2) Apple ID with an app-specific password"
read -rp "Choose 1 or 2: " choice
case "$choice" in
  1)
    read -rp "Path to AuthKey_XXXXXXXXXX.p8: " key
    read -rp "Key ID: " key_id
    read -rp "Issuer ID: " issuer
    base64 -i "$key" | gh secret set APPLE_API_KEY_P8
    gh secret set APPLE_API_KEY_ID --body "$key_id"
    gh secret set APPLE_API_ISSUER_ID --body "$issuer"
    ;;
  2)
    read -rp "Apple ID (email): " apple_id
    read -rp "Team ID (10 characters): " team_id
    read -rsp "App-specific password: " app_password
    echo
    gh secret set APPLE_ID --body "$apple_id"
    gh secret set APPLE_TEAM_ID --body "$team_id"
    gh secret set APPLE_APP_PASSWORD --body "$app_password"
    ;;
  *)
    echo "Skipped notarization; DMGs will be signed but not notarized." >&2
    ;;
esac

echo "Done. Push a tag like v0.1.0 to build a signed release."
