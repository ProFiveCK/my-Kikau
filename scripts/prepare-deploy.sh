#!/usr/bin/env bash
# Prepare publishable release artifacts after scripts/release.sh succeeds.
#
# This prepares the canonical build/release folder, regenerates Sparkle's
# appcast.xml, and creates/updates the GitHub release when gh is authenticated.
#
# Usage:
#   ./scripts/prepare-deploy.sh [build/myKikau-X.Y.Z.dmg] [download-url-prefix]
#
# Environment:
#   MYKIKAU_SKIP_GITHUB_RELEASE=1  Prepare artifacts but skip gh release.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/App/Info.plist)"
DMG="${1:-build/myKikau-${VERSION}.dmg}"
DOWNLOAD_URL_PREFIX="${2:-https://www.projectfive.co.ck/downloads/}"
RELEASE_DIR="build/release"
NOTES_FILE="${RELEASE_DIR}/release-notes-${VERSION}.md"

if [[ ! -f "$DMG" ]]; then
  echo "✘ DMG not found: $DMG"
  echo "  run scripts/release.sh first, or pass the DMG path explicitly:"
  echo "  ./scripts/prepare-deploy.sh build/myKikau-${VERSION}.dmg"
  exit 1
fi

# Avoid the confusing "appcast in build/ plus appcast in build/release/" state
# when update-appcast.sh was run manually against build/. build/release is the
# only canonical appcast folder.
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
rm -f build/appcast.xml build/*.delta

# Keep all root-level versioned DMGs in build/release so Sparkle can decide
# whether to generate delta updates. The release folder itself is generated
# output, not source-of-truth.
shopt -s nullglob
for release_dmg in build/myKikau-*.dmg; do
  cp "$release_dmg" "$RELEASE_DIR/"
done
shopt -u nullglob
cp "$DMG" "$RELEASE_DIR/"

echo "› generating appcast from $RELEASE_DIR"
./scripts/update-appcast.sh "$RELEASE_DIR" "$DOWNLOAD_URL_PREFIX"

DMG_NAME="$(basename "$DMG")"
DMG_SIZE="$(du -h "$DMG" | awk '{print $1}')"

python3 - "$VERSION" "$NOTES_FILE" <<'PY'
import re
import sys
from pathlib import Path

version, out_path = sys.argv[1], Path(sys.argv[2])
copy = Path("docs/WEBSITE_COPY.md").read_text()
pattern = rf"^### Version {re.escape(version)}\b.*?(?=^### Version |\Z)"
match = re.search(pattern, copy, flags=re.M | re.S)
if match:
    notes = match.group(0).strip()
else:
    notes = f"### Version {version}\n\nSee docs/WEBSITE_COPY.md for the current release notes."
out_path.write_text(notes + "\n")
PY

if [[ "${MYKIKAU_SKIP_GITHUB_RELEASE:-0}" != "1" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    TAG="v${VERSION}"
    echo "› creating/updating GitHub release ${TAG}"
    if gh release view "$TAG" >/dev/null 2>&1; then
      gh release upload "$TAG" "$DMG" --clobber
      gh release edit "$TAG" --title "$TAG" --notes-file "$NOTES_FILE"
    else
      gh release create "$TAG" "$DMG" --title "$TAG" --notes-file "$NOTES_FILE" --target "$(git rev-parse HEAD)"
    fi
  else
    echo "⚠ gh is not installed/authenticated; skipping GitHub release"
  fi
fi

cat <<EOF

✓ deploy artifacts prepared

Files to publish:
  $DMG -> ${DOWNLOAD_URL_PREFIX}${DMG_NAME}
  ${RELEASE_DIR}/appcast.xml -> https://www.projectfive.co.ck/apps/appcast.xml
  GitHub release notes: ${NOTES_FILE}

Website update checklist:
  - Update /apps/mykikau/ download button to version ${VERSION}
  - Show DMG size: ${DMG_SIZE}
  - Copy release notes from docs/WEBSITE_COPY.md
  - Keep docs/download-page-mockup.html in sync

Manual steps remaining:
  - Upload DMG
  - Upload appcast.xml
  - Update WordPress page
EOF
