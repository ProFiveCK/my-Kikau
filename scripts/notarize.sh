#!/usr/bin/env bash
# Sign, notarize, and staple a myKikau DMG so Gatekeeper accepts it with no warnings.
#
# One-time setup (per machine, not per release):
#   1. Generate an app-specific password at appleid.apple.com > Sign-In and Security
#      > App-Specific Passwords.
#   2. Store credentials in the keychain so notarytool doesn't need them every time:
#        xcrun notarytool store-credentials "myKikau-notary" \
#          --apple-id "you@example.com" \
#          --team-id "P523Y49P5B" \
#          --password "the-app-specific-password"
#
# Usage:
#   ./scripts/notarize.sh build/myKikau-0.2.0.dmg "Developer ID Application: Teu Teulilo (P523Y49P5B)"
#   # or export MYKIKAU_SIGN_IDENTITY first and omit the second argument.
#
# Requires: build/myKikau-*.dmg already built (./scripts/make-dmg.sh).

set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-}"
IDENTITY="${2:-${MYKIKAU_SIGN_IDENTITY:-}}"
KEYCHAIN_PROFILE="${MYKIKAU_NOTARY_PROFILE:-myKikau-notary}"

if [[ -z "$DMG" || ! -f "$DMG" ]]; then
  echo "✘ usage: ./scripts/notarize.sh <path-to-dmg> [\"Developer ID Application: ...\"]"
  exit 1
fi
if [[ -z "$IDENTITY" ]]; then
  echo "✘ no signing identity — pass as \$2 or export MYKIKAU_SIGN_IDENTITY"
  exit 1
fi

echo "› signing $DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "› submitting to Apple's notary service (usually a few minutes; can be longer)"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo "› stapling the notarization ticket"
xcrun stapler staple "$DMG"

echo "› validating"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

echo "✓ $DMG is signed, notarized, and stapled — safe to publish"
