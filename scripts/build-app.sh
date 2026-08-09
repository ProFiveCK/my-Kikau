#!/usr/bin/env bash
# Build myKikau into a proper macOS .app bundle.
#
# SwiftPM produces a bare executable; this script wraps it into a .app with the
# Info.plist and AppIcon.icns so Finder/Dock show the app icon.
#
# Usage:
#   ./scripts/build-app.sh              # debug build -> build/myKikau.app
#   ./scripts/build-app.sh --release    # release build -> build/myKikau.app
#
# Requires: swift, iconutil (macOS built-in).

set -euo pipefail

cd "$(dirname "$0")/.."

config="debug"
swift_flags=""
if [[ "${1:-}" == "--release" ]]; then
  config="release"
  swift_flags="-c release"
fi

echo "› swift build ($config)"
swift build $swift_flags

# Locate the built executable.
bin_dir="$(swift build --show-bin-path $swift_flags)"
executable="$bin_dir/myKikau"

if [[ ! -f "$executable" ]]; then
  echo "✘ executable not found at $executable"
  exit 1
fi

# Fresh .app bundle.
app_bundle="build/myKikau.app"
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"

echo "› assembling $app_bundle"

# Copy the executable.
cp "$executable" "$app_bundle/Contents/MacOS/myKikau"
chmod +x "$app_bundle/Contents/MacOS/myKikau"

# Copy the Info.plist.
cp Sources/App/Info.plist "$app_bundle/Contents/Info.plist"

# Regenerate AppIcon.icns from the iconset (iconutil-compatible), then copy it in.
# The .iconset directory holds the 10 named size variants that iconutil compiles.
if [[ -d AppIcon/AppIcon.iconset ]]; then
  echo "› iconutil AppIcon.iconset -> AppIcon.icns"
  iconutil -c icns -o "$app_bundle/Contents/Resources/AppIcon.icns" AppIcon/AppIcon.iconset
elif [[ -f AppIcon/AppIcon.icns ]]; then
  echo "› using existing AppIcon.icns"
  cp AppIcon/AppIcon.icns "$app_bundle/Contents/Resources/AppIcon.icns"
else
  echo "⚠ no app icon found; bundle will have no icon"
fi

# Touch the bundle so LaunchServices picks up changes.
touch "$app_bundle"

echo "✓ built $app_bundle"
echo "  open with: open $app_bundle"