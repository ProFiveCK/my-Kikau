#!/usr/bin/env bash
# Package build/myKikau.app as an installer .pkg for managed deployment
# (Jamf, Intune, Kandji, Mosyle — anything that pushes a flat package).
#
# The package installs /Applications/myKikau.app and nothing else: no scripts,
# no launch daemons. The command-line tool rides along inside the bundle at
# Contents/Helpers/mykikau-cli.
#
# Usage:
#   ./scripts/make-pkg.sh                                   # unsigned, for testing
#   ./scripts/make-pkg.sh "Developer ID Installer: Name (TEAMID)"
#   # or: export MYKIKAU_INSTALLER_IDENTITY="Developer ID Installer: ..."
#
# A package for distribution must be signed with a *Developer ID Installer*
# certificate (not the "Developer ID Application" one used by sign.sh) and
# notarized:
#   xcrun notarytool submit build/myKikau-<version>.pkg --keychain-profile "myKikau-notary" --wait
#   xcrun stapler staple build/myKikau-<version>.pkg
#
# Requires: build/myKikau.app already built and signed
# (./scripts/build-app.sh --release && ./scripts/sign.sh).

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-${MYKIKAU_INSTALLER_IDENTITY:-}}"
APP_BUNDLE="build/myKikau.app"
PKG_IDENTIFIER="com.profiveck.myKikau.pkg"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "✘ $APP_BUNDLE not found — run ./scripts/build-app.sh --release and ./scripts/sign.sh first"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/root"
mkdir -p "$ROOT/Applications"
# ditto preserves the code signature, extended attributes and symlinks.
ditto "$APP_BUNDLE" "$ROOT/Applications/myKikau.app"

# Without this the Installer "relocates" the payload to wherever it finds an
# existing copy of the app (a Downloads folder, say) instead of /Applications.
COMPONENTS="$WORK/components.plist"
pkgbuild --analyze --root "$ROOT" "$COMPONENTS" >/dev/null
# (Newer pkgbuild versions omit the key from the analysis, so add-or-replace.)
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENTS"

UNSIGNED="$WORK/myKikau-unsigned.pkg"
echo "› pkgbuild myKikau $VERSION"
pkgbuild \
  --root "$ROOT" \
  --component-plist "$COMPONENTS" \
  --install-location "/" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$VERSION" \
  "$UNSIGNED" >/dev/null

OUTPUT="build/myKikau-${VERSION}.pkg"
if [[ -n "$IDENTITY" ]]; then
  echo "› productsign"
  productsign --sign "$IDENTITY" --timestamp "$UNSIGNED" "$OUTPUT"
  pkgutil --check-signature "$OUTPUT"
  echo "✓ signed package: $OUTPUT"
  echo "  next: notarize and staple (see the header of this script)"
else
  cp "$UNSIGNED" "$OUTPUT"
  echo "✓ unsigned package: $OUTPUT"
  echo "  for testing only — pass a Developer ID Installer identity to sign it"
fi
