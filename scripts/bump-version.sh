#!/usr/bin/env bash
# Bump myKikau's Info.plist version fields.
#
# Usage:
#   scripts/bump-version.sh patch       # 0.2.1 -> 0.2.2, build +1
#   scripts/bump-version.sh minor       # 0.2.1 -> 0.3.0, build +1
#   scripts/bump-version.sh major       # 0.2.1 -> 1.0.0, build +1
#   scripts/bump-version.sh 0.3.0       # explicit semver, build +1
#   scripts/bump-version.sh 0.3.0 7     # explicit semver + build

set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="Sources/App/Info.plist"
MODE="${1:-}"
BUILD_OVERRIDE="${2:-}"

if [[ -z "$MODE" ]]; then
  echo "✘ usage: scripts/bump-version.sh <patch|minor|major|X.Y.Z> [build-number]"
  exit 1
fi

current_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
current_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

IFS=. read -r major minor patch <<< "$current_version"
if [[ -z "${major:-}" || -z "${minor:-}" || -z "${patch:-}" ]]; then
  echo "✘ current version is not semver: $current_version"
  exit 1
fi

case "$MODE" in
  patch)
    patch=$((patch + 1))
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  *)
    if [[ ! "$MODE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "✘ version must be patch, minor, major, or explicit X.Y.Z: $MODE"
      exit 1
    fi
    IFS=. read -r major minor patch <<< "$MODE"
    ;;
esac

new_version="${major}.${minor}.${patch}"

if [[ -n "$BUILD_OVERRIDE" ]]; then
  if [[ ! "$BUILD_OVERRIDE" =~ ^[0-9]+$ ]]; then
    echo "✘ build number must be an integer: $BUILD_OVERRIDE"
    exit 1
  fi
  new_build="$BUILD_OVERRIDE"
else
  if [[ ! "$current_build" =~ ^[0-9]+$ ]]; then
    echo "✘ current build number is not an integer: $current_build"
    exit 1
  fi
  new_build=$((current_build + 1))
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new_version" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $new_build" "$PLIST"

echo "✓ bumped myKikau $current_version ($current_build) -> $new_version ($new_build)"
