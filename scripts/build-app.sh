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
# Requires: swift, iconutil, otool, install_name_tool, codesign (all macOS/Xcode-CLT built-in).

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

# Embed Sparkle.framework.
#
# Sparkle ships as a binary xcframework. `swift build` resolves it and copies
# the macOS .framework slice into the build products directory so `swift run`
# and Xcode can find it at runtime — but a hand-assembled .app bundle needs
# that framework physically embedded in Contents/Frameworks, plus an rpath
# telling the executable to look there. Skipping this produces an app that
# builds, signs, and notarizes cleanly but crashes instantly on launch with
# "Library not loaded: @rpath/Sparkle.framework".
frameworks_dir="$app_bundle/Contents/Frameworks"
mkdir -p "$frameworks_dir"

sparkle_framework="$(find "$bin_dir" -maxdepth 2 -name "Sparkle.framework" -print -quit 2>/dev/null || true)"
if [[ -z "$sparkle_framework" ]]; then
  # Fall back to searching the whole .build tree in case SwiftPM's layout differs.
  sparkle_framework="$(find .build -name "Sparkle.framework" -path "*macos*" -print -quit 2>/dev/null || true)"
fi

if [[ -z "$sparkle_framework" ]]; then
  echo "✘ could not locate Sparkle.framework under .build — the app would crash on launch"
  echo "  try: swift build $swift_flags   (to make sure the Sparkle package resolved)"
  exit 1
fi

echo "› embedding Sparkle.framework ($sparkle_framework)"
rm -rf "$frameworks_dir/Sparkle.framework"
cp -R "$sparkle_framework" "$frameworks_dir/Sparkle.framework"

# Make sure the executable actually looks in Contents/Frameworks for @rpath loads.
if ! otool -l "$app_bundle/Contents/MacOS/myKikau" | grep -F -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_bundle/Contents/MacOS/myKikau"
fi

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

# Copy the menu bar (status item) icon — a separate, simplified monochrome
# vector distinct from AppIcon.icns. It's loaded at runtime with isTemplate =
# true so AppKit recolors it automatically for the light/dark menu bar, the
# same as every other status item. Kept as a small standalone PDF (not baked
# into AppIcon.icns, which is fixed-size raster and full color) so it stays
# crisp at any menu bar scale.
if [[ -f AppIcon/MenuBarIcon.pdf ]]; then
  echo "› copying MenuBarIcon.pdf"
  cp AppIcon/MenuBarIcon.pdf "$app_bundle/Contents/Resources/MenuBarIcon.pdf"
else
  echo "⚠ AppIcon/MenuBarIcon.pdf not found; menu bar will fall back to the built-in drawn icon"
fi

# Touch the bundle so LaunchServices picks up changes.
touch "$app_bundle"

# SwiftPM signs the bare executable, then this script copies it into a bundle and
# may mutate its rpaths with install_name_tool. That invalidates the original
# page signature on recent macOS releases and dyld kills the app before main().
# Ad-hoc sign the finished local bundle so debug builds are launchable; release
# distribution still gets a Developer ID signature later via scripts/sign.sh.
echo "› ad-hoc codesign local app bundle"
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"

echo "✓ built $app_bundle"
echo "  open with: open $app_bundle"
