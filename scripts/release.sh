#!/usr/bin/env bash
# One-command release pipeline: build -> sign -> package -> notarize.
#
# Replaces running build-app.sh / sign.sh / make-dmg.sh / notarize.sh by hand.
# Fails fast (before doing any work) if the signing identity isn't available,
# so you don't sit through a build+notarize cycle only to hit a missing-arg
# error at the end.
#
# Usage:
#   ./scripts/release.sh                        # uses $MYKIKAU_SIGN_IDENTITY
#   ./scripts/release.sh "Developer ID Application: Teu Teulilo (P523Y49P5B)"
#
# One-time setup so you never have to pass the identity again — add to
# ~/.zshrc:
#   export MYKIKAU_SIGN_IDENTITY="Developer ID Application: Teu Teulilo (P523Y49P5B)"
#
# Requires: everything build-app.sh / sign.sh / make-dmg.sh / notarize.sh need,
# including a one-time `xcrun notarytool store-credentials "myKikau-notary" ...`
# (see notarize.sh header).

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-${MYKIKAU_SIGN_IDENTITY:-}}"

if [[ -z "$IDENTITY" ]]; then
  echo "✘ no signing identity — pass it as an argument or export MYKIKAU_SIGN_IDENTITY."
  echo ""
  echo "  Add this once to ~/.zshrc so you never have to type it again:"
  echo "    export MYKIKAU_SIGN_IDENTITY=\"Developer ID Application: Teu Teulilo (P523Y49P5B)\""
  echo ""
  echo "  Then: source ~/.zshrc   (or just open a new terminal tab)"
  exit 1
fi

echo "═══ 1/4  build ═══"
./scripts/build-app.sh --release

echo "═══ 2/4  sign ═══"
./scripts/sign.sh "$IDENTITY"

echo "═══ 3/4  package ═══"
./scripts/make-dmg.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/myKikau.app/Contents/Info.plist)"
DMG="build/myKikau-${VERSION}.dmg"

echo "═══ 4/4  notarize ═══"
./scripts/notarize.sh "$DMG" "$IDENTITY"

echo ""
echo "✓ release ready: $DMG"
echo ""
echo "Next (manual — depends on how you publish to projectfive.co.ck):"
echo "  1. ./scripts/update-appcast.sh <release-folder-containing-the-dmg>"
echo "  2. Upload $DMG + appcast.xml to https://www.projectfive.co.ck/apps/"
