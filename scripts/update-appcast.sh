#!/usr/bin/env bash
# Regenerate appcast.xml from every DMG in a release folder, using Sparkle's own
# `generate_appcast` tool (signs each enclosure with the EdDSA key `generate_keys`
# stored in your login keychain).
#
# One-time setup:
#   1. swift build   (resolves the Sparkle package so its bundled CLI tools exist
#                      under .build/checkouts/Sparkle/... — or `brew install --cask
#                      sparkle` for a standalone copy of the same tools)
#   2. Find generate_keys / sign_update / generate_appcast, e.g.:
#        find .build -name generate_appcast
#   3. Run generate_keys once to create the EdDSA keypair; it prints the public
#      key — paste that into Sources/App/Info.plist's SUPublicEDKey. The private
#      key is stored in your keychain, not in this repo.
#
# Usage:
#   ./scripts/update-appcast.sh /path/to/release-folder [download-url-prefix]
#
# The release folder should contain your signed, notarized DMG(s), each
# optionally paired with a same-named .html or .txt release-notes file
# (myKikau-0.2.0.dmg + myKikau-0.2.0.html).
#
# download-url-prefix tells Sparkle where the DMGs will actually be reachable
# from — it's baked into each <enclosure url="..."> in the generated feed, so
# it must match wherever you actually upload the DMGs, which is NOT
# necessarily the same folder as appcast.xml itself (SUFeedURL is
# .../apps/appcast.xml, but DMGs may live at .../downloads/). Defaults to
# projectfive.co.ck's downloads folder; pass a second argument to override.

set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE_DIR="${1:-}"
DOWNLOAD_URL_PREFIX="${2:-https://www.projectfive.co.ck/downloads/}"
if [[ -z "$RELEASE_DIR" || ! -d "$RELEASE_DIR" ]]; then
  echo "✘ usage: ./scripts/update-appcast.sh /path/to/release-folder [download-url-prefix]"
  exit 1
fi

GENERATE_APPCAST="$(find .build -name generate_appcast -type f 2>/dev/null | head -1)"
if [[ -z "$GENERATE_APPCAST" ]]; then
  GENERATE_APPCAST="$(command -v generate_appcast || true)"
fi
if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "✘ generate_appcast not found."
  echo "  run 'swift build' first to resolve the Sparkle package, or"
  echo "  'brew install --cask sparkle' for a standalone copy of the CLI tools."
  exit 1
fi

echo "› using $GENERATE_APPCAST"
echo "› DMG download URL prefix: $DOWNLOAD_URL_PREFIX"
"$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$RELEASE_DIR"

echo "✓ wrote $RELEASE_DIR/appcast.xml"
echo "  upload appcast.xml to the URL set in Info.plist's SUFeedURL (apps/appcast.xml)"
echo "  — the DMG(s) themselves stay wherever \$DOWNLOAD_URL_PREFIX says they are"
