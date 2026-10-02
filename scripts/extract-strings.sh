#!/usr/bin/env bash
# Refresh Resources/Localizable.xcstrings from the source code.
#
# Compiles the package with the Swift compiler's own string extraction turned
# on, so every string the type checker knows is localisable is found — SwiftUI
# text, String(localized:), LocalizedStringResource — then merges the result
# into the String Catalog. Existing translations are kept; strings that no
# longer exist are marked stale rather than deleted.
#
# Run it after changing user-facing text, then commit the catalog.
#
# Usage: ./scripts/extract-strings.sh

set -euo pipefail
cd "$(dirname "$0")/.."

CATALOG="Resources/Localizable.xcstrings"
WORK=".build-loc"
DATA="$PWD/$WORK/stringsdata"

# Always a clean build: an incremental one only re-emits strings for the files
# it recompiles, and everything else would then be marked stale.
rm -rf "$WORK"
mkdir -p "$DATA"

echo "› compiling with string extraction"
swift build --build-path "$WORK/build" \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$DATA" >/dev/null

if [[ ! -f "$CATALOG" ]]; then
  mkdir -p "$(dirname "$CATALOG")"
  printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' > "$CATALOG"
fi

echo "› syncing $CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$DATA"/*.stringsdata

count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["strings"]))' "$CATALOG")"
echo "✓ $CATALOG — $count strings"
