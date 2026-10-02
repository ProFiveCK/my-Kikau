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
#   MYKIKAU_SKIP_GIT_PUSH=1        Do not push the current branch before release.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/App/Info.plist)"
DMG="${1:-build/myKikau-${VERSION}.dmg}"
DOWNLOAD_URL_PREFIX="${2:-https://www.projectfive.co.ck/downloads/}"
RELEASE_DIR="build/release"
NOTES_FILE="${RELEASE_DIR}/release-notes-${VERSION}.md"
UPLOAD_DIR="website-upload/${VERSION}"
PF_APPS_SOURCE="docs/pf-apps.php"
PF_APPS_STAGED="${UPLOAD_DIR}/pf-apps.php"

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
if not match:
    print(f"✘ Version {version} not found in docs/WEBSITE_COPY.md", file=sys.stderr)
    print("  Add a '### Version {version}' section with release notes before deploying.", file=sys.stderr)
    sys.exit(1)
notes = match.group(0).strip()
out_path.write_text(notes + "\n")
PY

if [[ "${MYKIKAU_SKIP_GITHUB_RELEASE:-0}" != "1" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    TAG="v${VERSION}"
    TARGET_COMMIT="$(git rev-parse HEAD)"
    CURRENT_BRANCH="$(git branch --show-current)"
    if [[ -n "$CURRENT_BRANCH" && "${MYKIKAU_SKIP_GIT_PUSH:-0}" != "1" ]]; then
      echo "› pushing ${CURRENT_BRANCH} to origin for GitHub release target"
      git push origin "HEAD:${CURRENT_BRANCH}"
    fi
    echo "› creating/updating GitHub release ${TAG}"
    if gh release view "$TAG" >/dev/null 2>&1; then
      gh release upload "$TAG" "$DMG" --clobber
      gh release edit "$TAG" --title "$TAG" --notes-file "$NOTES_FILE"
    else
      gh release create "$TAG" "$DMG" --title "$TAG" --notes-file "$NOTES_FILE" --target "$TARGET_COMMIT"
    fi
  else
    echo "⚠ gh is not installed/authenticated; skipping GitHub release"
  fi
fi

rm -rf "$UPLOAD_DIR"
mkdir -p "$UPLOAD_DIR"
cp "$DMG" "$UPLOAD_DIR/"
cp "${RELEASE_DIR}/appcast.xml" "$UPLOAD_DIR/"

# Stage pf-apps.php with the release version and download URL substituted in,
# so the deploy script uploads a version-correct copy without manual edits.
python3 - "$VERSION" "$PF_APPS_SOURCE" "$PF_APPS_STAGED" <<'PY'
import re, sys
from pathlib import Path

version, src, dst = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
text = src.read_text()
# Replace the version field and any myKikau-<version>.dmg references.
text = re.sub(r"'version'\s+=>\s+'[^']*'", f"'version'  => '{version}'", text)
text = re.sub(r"myKikau-\d+\.\d+\.\d+\.dmg", f"myKikau-{version}.dmg", text)
dst.write_text(text)
print(f"  staged {dst.name} with version {version}")
PY

cat <<EOF

✓ deploy artifacts prepared

Files to publish:
  $DMG -> ${DOWNLOAD_URL_PREFIX}${DMG_NAME}
  ${RELEASE_DIR}/appcast.xml -> https://www.projectfive.co.ck/downloads/appcast.xml
  GitHub release notes: ${NOTES_FILE}

Website upload folder:
  ${UPLOAD_DIR}/
  - ${DMG_NAME}
  - appcast.xml
  - pf-apps.php (version ${VERSION}, download URL updated)

Website deploy:
  python3 scripts/deploy-website.py

  The deploy script edits pf_apps() in the theme functions.php on the server,
  so the /apps/ page shows version ${VERSION} and the correct DMG download link.
EOF
