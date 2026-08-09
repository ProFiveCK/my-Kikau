#!/usr/bin/env bash
# Codesign build/myKikau.app with a Developer ID Application certificate + Hardened
# Runtime. Required before notarization will accept the build.
#
# One-time setup: enroll in the Apple Developer Program and create a "Developer ID
# Application" certificate (Xcode > Settings > Accounts > Manage Certificates, or
# developer.apple.com > Certificates, Identifiers & Profiles). It must be installed
# in your login keychain.
#
# Usage:
#   ./scripts/sign.sh "Developer ID Application: Teu Teulilo (P523Y49P5B)"
#   # or:
#   export MYKIKAU_SIGN_IDENTITY="Developer ID Application: Teu Teulilo (P523Y49P5B)"
#   ./scripts/sign.sh
#
# Requires: build/myKikau.app already built (./scripts/build-app.sh --release).

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-${MYKIKAU_SIGN_IDENTITY:-}}"
APP_BUNDLE="build/myKikau.app"
ENTITLEMENTS="myKikau.entitlements"

if [[ -z "$IDENTITY" ]]; then
  echo "✘ no signing identity given."
  echo "  usage: ./scripts/sign.sh \"Developer ID Application: Teu Teulilo (P523Y49P5B)\""
  echo "  or export MYKIKAU_SIGN_IDENTITY=\"Developer ID Application: ...\""
  echo ""
  echo "  list identities in your keychain with:"
  echo "    security find-identity -v -p codesigning"
  exit 1
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "✘ $APP_BUNDLE not found — run ./scripts/build-app.sh --release first"
  exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "✘ $ENTITLEMENTS not found at repo root"
  exit 1
fi

echo "› codesign (deep, hardened runtime, timestamped)"
codesign --deep --force \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  --timestamp \
  "$APP_BUNDLE"

echo "› verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "› Gatekeeper dry run (expect 'no usable signature' until notarized+stapled — that's normal here)"
spctl -a -vvv -t exec "$APP_BUNDLE" || true

echo "✓ signed $APP_BUNDLE"
echo "  next: ./scripts/make-dmg.sh"
