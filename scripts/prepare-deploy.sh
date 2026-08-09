#!/usr/bin/env bash
# Prepare publishable release artifacts after scripts/release.sh succeeds.
#
# This copies the notarized DMG into build/release, regenerates Sparkle's
# appcast.xml, and prints the manual upload / website / GitHub steps that still
# require credentials or a connected hosting/GitHub tool.
#
# Usage:
#   ./scripts/prepare-deploy.sh [build/myKikau-X.Y.Z.dmg] [download-url-prefix]

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/App/Info.plist)"
DMG="${1:-build/myKikau-${VERSION}.dmg}"
DOWNLOAD_URL_PREFIX="${2:-https://www.projectfive.co.ck/downloads/}"
RELEASE_DIR="build/release"

if [[ ! -f "$DMG" ]]; then
  echo "✘ DMG not found: $DMG"
  echo "  run scripts/release.sh first, or pass the DMG path explicitly:"
  echo "  ./scripts/prepare-deploy.sh build/myKikau-${VERSION}.dmg"
  exit 1
fi

mkdir -p "$RELEASE_DIR"
cp "$DMG" "$RELEASE_DIR/"

echo "› generating appcast from $RELEASE_DIR"
./scripts/update-appcast.sh "$RELEASE_DIR" "$DOWNLOAD_URL_PREFIX"

DMG_NAME="$(basename "$DMG")"
DMG_SIZE="$(du -h "$DMG" | awk '{print $1}')"

cat <<EOF

✓ deploy artifacts prepared

Files to publish:
  $DMG -> ${DOWNLOAD_URL_PREFIX}${DMG_NAME}
  ${RELEASE_DIR}/appcast.xml -> https://www.projectfive.co.ck/apps/appcast.xml

Website update checklist:
  - Update /apps/mykikau/ download button to version ${VERSION}
  - Show DMG size: ${DMG_SIZE}
  - Copy release notes from docs/WEBSITE_COPY.md
  - Keep docs/download-page-mockup.html in sync

GitHub release:
  - Tag: v${VERSION}
  - Attach: $DMG

If GitHub CLI is authenticated, this part can be scripted:
  gh release create v${VERSION} "$DMG" --title "v${VERSION}" --notes-file <notes.md>

Manual unless hosting/GitHub credentials are connected:
  - Upload DMG
  - Upload appcast.xml
  - Update WordPress page
  - Create GitHub release if gh is not authenticated
EOF
