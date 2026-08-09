#!/usr/bin/env bash
# Lint myKikau with SwiftFormat and SwiftLint, whichever are installed.
# Exit status is non-zero if any installed linter reports errors.
#
# Install the tools (one-time):
#   brew install swiftformat swiftlint
#
# Usage:
#   ./scripts/lint.sh          # check only (no modifications)
#   ./scripts/lint.sh --fix    # auto-format with SwiftFormat

set -uo pipefail

cd "$(dirname "$0")/.."

mode="check"
if [[ "${1:-}" == "--fix" ]]; then
  mode="fix"
fi

status=0

# --- SwiftFormat (NickLockwood) ---
if command -v swiftformat >/dev/null 2>&1; then
  if [[ "$mode" == "fix" ]]; then
    echo "› swiftformat (format)"
    swiftformat . --config .swiftformat || status=$?
  else
    echo "› swiftformat (lint)"
    swiftformat . --config .swiftformat --dryrun --strict || status=$?
  fi
else
  echo "› swiftformat not installed; skipping (brew install swiftformat to enable)"
fi

# --- SwiftLint (Realm) ---
if command -v swiftlint >/dev/null 2>&1; then
  echo "› swiftlint"
  if [[ "$mode" == "fix" ]]; then
    swiftlint --fix --config .swiftlint.yml || true
  fi
  swiftlint --config .swiftlint.yml || status=$?
else
  echo "› swiftlint not installed; skipping (brew install swiftlint to enable)"
fi

if [[ "$status" -ne 0 ]]; then
  echo "✘ lint reported issues (exit $status)"
  exit "$status"
fi
echo "✓ lint clean"