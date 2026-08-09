#!/usr/bin/env bash
# Package the signed build/myKikau.app into a distributable, drag-to-Applications DMG.
#
# Usage:
#   ./scripts/make-dmg.sh [version]
#
# If version is omitted, it's read from the built app's Info.plist.
# Requires: build/myKikau.app already built and signed
#   (./scripts/build-app.sh --release && ./scripts/sign.sh "...")

set -euo pipefail
cd "$(dirname "$0")/.."

APP_BUNDLE="build/myKikau.app"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "✘ $APP_BUNDLE not found — build and sign first"
  exit 1
fi

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "0.0.0")}"
DMG_NAME="myKikau-${VERSION}.dmg"
STAGING="build/dmg-staging"

echo "› staging DMG contents (myKikau ${VERSION})"
rm -rf "$STAGING" "build/$DMG_NAME"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "› creating build/$DMG_NAME"
hdiutil create -volname "myKikau ${VERSION}" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "build/$DMG_NAME"

rm -rf "$STAGING"

echo "✓ built build/$DMG_NAME"
echo "  next: ./scripts/notarize.sh build/$DMG_NAME \"Developer ID Application: ...\""
