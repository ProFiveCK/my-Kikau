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

# Sign inside-out: every nested piece of code first, the app bundle last.
# `codesign --deep` is not used for signing — Apple and Sparkle both advise
# against it: it applies the app's entitlements to nested code that shouldn't
# have them and can skip helpers it doesn't recognise.
#
# MYKIKAU_SIGN_NO_TIMESTAMP=1 drops the secure timestamp, for a local dry run
# with an ad-hoc identity ("-"). Release signing must keep it: notarization
# rejects a signature without one.
TIMESTAMP=(--timestamp)
if [[ "${MYKIKAU_SIGN_NO_TIMESTAMP:-}" == "1" ]]; then
  TIMESTAMP=()
fi

sign() {
  # The ${arr[@]+…} form keeps an empty array from tripping `set -u` on the
  # bash 3.2 that ships with macOS.
  codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --sign "$IDENTITY" "$@"
}

SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  echo "› codesign Sparkle.framework (inside-out)"
  SPARKLE_VERSION="$SPARKLE/Versions/Current"
  for nested in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app"; do
    if [[ -e "$nested" ]]; then
      if [[ "$nested" == *Downloader.xpc ]]; then
        # Downloader.xpc ships with its own sandbox entitlements; keep them.
        sign --preserve-metadata=entitlements "$nested"
      else
        sign "$nested"
      fi
    fi
  done
  sign "$SPARKLE"
fi

# Any other embedded frameworks or dylibs.
if [[ -d "$APP_BUNDLE/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' nested; do
    [[ "$nested" == "$SPARKLE" ]] && continue
    echo "› codesign $(basename "$nested")"
    sign "$nested"
  done < <(find "$APP_BUNDLE/Contents/Frameworks" -mindepth 1 -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) -print0)
fi

# Bundled helper executables (the command-line tool).
if [[ -d "$APP_BUNDLE/Contents/Helpers" ]]; then
  while IFS= read -r -d '' helper; do
    echo "› codesign $(basename "$helper")"
    sign "$helper"
  done < <(find "$APP_BUNDLE/Contents/Helpers" -type f -perm +111 -print0)
fi

# The privileged helper. Its signing identifier is what the app checks before
# talking to it, so it is set explicitly rather than derived from the file name.
if [[ -f "$APP_BUNDLE/Contents/MacOS/myKikauHelper" ]]; then
  echo "› codesign myKikauHelper"
  sign --identifier com.profiveck.myKikau.helper "$APP_BUNDLE/Contents/MacOS/myKikauHelper"
fi

echo "› codesign myKikau.app (hardened runtime, entitlements)"
sign --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

echo "› verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "› Gatekeeper dry run (expect 'no usable signature' until notarized+stapled — that's normal here)"
spctl -a -vvv -t exec "$APP_BUNDLE" || true

echo "✓ signed $APP_BUNDLE"
echo "  next: ./scripts/make-dmg.sh"
