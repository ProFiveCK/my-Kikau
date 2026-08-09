# Project Setup Guide

This guide covers everything needed to build, run, and develop myKikau.

## Prerequisites

- **macOS 14.0 (Sonoma) or later** — the app uses `MenuBarExtra`, `ContentUnavailableView`, and other macOS 14+ SwiftUI APIs
- **Xcode 15.0 or later** (recommended for full app bundle, signing, and menu bar HUD)
- **Swift 6.0+ / SwiftPM** — verify with `swift --version`
- **Git** — for cloning and contributing

## Quick Start

```bash
# Clone
git clone https://github.com/ProFiveCK/my-Kikau.git
cd my-Kikau

# Build (command line)
swift build

# Run tests
swift test

# Open in Xcode for the full app experience
open Package.swift
```

## Building

### Command Line (SwiftPM)

```bash
swift build              # Debug build
swift build -c release   # Release build
```

The built executable lands at `.build/debug/myKikau` (or `.build/release/myKikau`).

### Xcode

Open `Package.swift` in Xcode:

```bash
open Package.swift
```

Xcode resolves the SwiftPM package automatically. Select the `myKikau` scheme and run (⌘R) to launch the app with the menu bar HUD and full window UI.

> **Note:** Running the bare executable from SwiftPM (`.build/debug/myKikau`) launches the SwiftUI window but the `MenuBarExtra` works best inside an `.app` bundle. For the menu bar HUD experience, run via Xcode or build an `.app` bundle.

## Running the App

```bash
# From SwiftPM build
.build/debug/myKikau

# From Xcode — ⌘R to run
```

### First Run

1. The main window opens on the Status dashboard (sidebar: Status, Clean, Uninstall, Analyse, Duplicates, Optimise, History) — Status doubles as a hub with quick-launch cards into every other screen
2. The menu bar HUD icon (✨ sparkles) appears in the menu bar with live CPU/memory/disk/battery stats
3. On first scan, macOS may prompt for access to `~/Library` subdirectories — approve these to enable cleanup features

## Testing

```bash
swift test                                    # All tests
swift test --filter PathProtectionTests        # Specific suite
swift test --filter SafeFileDeleterTests       # Another suite
```

Tests use temp directories and never touch real user data. The test suite covers:

- **PathProtection** — protected paths, bundle ID matching, EDR detection
- **SafeFileDeleter** — preview, dry-run, Trash execution, size measurement
- **HealthScore** — health formula, battery health, uptime formatting

## Architecture

```
myKikau/
├── Package.swift              SwiftPM manifest (4 targets: App, Core, Features, UI)
├── Sources/
│   ├── App/                   @main entry, scene composition, menu bar HUD, feature views
│   │   ├── myKikauApp.swift   @main App with WindowGroup + MenuBarExtra
│   │   ├── MenuBar/HUDView.swift  Live status popover
│   │   ├── CleanView.swift    Clean feature UI
│   │   ├── UninstallView.swift Uninstall feature UI
│   │   ├── AnalyzeView.swift   Disk analyzer UI
│   │   ├── StatusView.swift    System status dashboard UI
│   │   ├── OptimizeView.swift   Maintenance tasks UI
│   │   ├── PurgeView.swift     Project purge UI
│   │   └── HistoryView.swift   Operation log viewer UI
│   ├── Core/                  Safety-first core services
│   │   ├── SafeFileDeleter.swift  Single deletion funnel (preview + execute)
│   │   ├── PathProtection.swift   Protected paths + bundle IDs
│   │   ├── OperationLog.swift     JSONL operation log
│   │   ├── Permissions.swift      TCC security-scoped bookmarks
│   │   └── ByteSizeFormatter.swift Human-readable size formatting
│   ├── Features/              Feature logic (platform APIs, no UI)
│   │   ├── Clean/CleanScanner.swift
│   │   ├── Uninstall/{AppInventory,LeftoverFinder}.swift
│   │   ├── Analyze/DiskScanner.swift
│   │   ├── Status/{MetricsCollector,MetricsSnapshot,HealthScore}.swift
│   │   ├── Optimize/MaintenanceCatalog.swift
│   │   └── Purge/ProjectArtifactScanner.swift
│   └── UI/                   Shared SwiftUI components
│       ├── PlanReviewView.swift  Dry-run preview + confirm (shared)
│       └── Components/SizeBar.swift
├── Tests/myKikauTests/        Unit tests (Swift Testing framework)
└── docs/SETUP.md              This file
```

### Module Dependency Graph

```
App → UI → Features → Core
```

- **Core** — no dependencies, pure safety primitives
- **Features** — depends on Core, uses Foundation/Darwin/IOKit
- **UI** — depends on Core + Features, SwiftUI only
- **App** — depends on all, provides `@main` and window/menu bar scenes

## Safety Design

myKikau inherits Mole's safety-first principles:

1. **Single deletion funnel** — every deletion routes through `SafeFileDeleter` which:
   - Routes to Trash by default (Finder-recoverable)
   - Writes to the operation log (`~/Library/Logs/myKikau/operations.log` as JSONL)
   - Honors dry-run mode (no mutation, logged as `dryRun`)
   - Checks `PathProtection` before any operation

2. **Protected paths** — `/System`, `/Library/Apple`, `/usr`, `/bin`, `/sbin`, `/Library/Updates`, Software Update staging trees are never modified

3. **Critical bundle IDs** — 90+ system bundle IDs (Finder, Dock, Safari, SystemSettings, etc.) are protected from uninstallation. User-installed Apple apps (Xcode, Final Cut Pro) are explicitly allowed.

4. **Endpoint security** — EDR/MDM agent bundle prefixes (CrowdStrike, SentinelOne, ESET, Jamf) are never touched to avoid tamper detection

5. **Exact bundle-ID matching** — leftover files match by exact bundle ID only. No vendor-prefix, generic-name, or fallback-wildcard matching (per Mole AGENTS.md)

6. **Preview before delete** — every destructive action shows a `PlanReviewView` with item counts, sizes, and a Dry Run toggle before execution

## Reference

Logic reimplemented natively in Swift, informed by [Mole](https://github.com/tw93/Mole) (GPL-3.0, Go + Bash CLI). See `../Mole/AGENTS.md` for the original safety rules and product direction that guide this project.

Key Mole files referenced during porting:

- `lib/core/file_ops.sh` — deletion funnel design
- `lib/core/app_protection_data.sh` — protected bundle ID list
- `lib/clean/*.sh` — cleanup target paths
- `lib/uninstall/*.sh` — leftover teardown logic
- `lib/optimize/catalog.sh` — maintenance task catalog
- `cmd/status/metrics.go` + `metrics_health.go` — metrics + health score

## Release Process

myKikau is distributed directly from the website (not the Mac App Store) — see
`docs/MODERNIZATION_REVIEW.md` §5 for why. Every release ships as a signed,
notarized, stapled DMG.

### Versioning

Bump both keys in `Sources/App/Info.plist` before tagging a release:

- `CFBundleShortVersionString` — the user-facing semver (`0.2.0`)
- `CFBundleVersion` — a strictly increasing build number (`2`, `3`, ...), bumped on
  every build even between semver releases

Tag the release commit `vX.Y.Z` to match.

### Build → sign → package → notarize

One command runs the whole pipeline:

```bash
./scripts/release.sh
```

It fails fast (before building anything) if it can't find a signing identity,
and prints the final DMG path when done. Under the hood it's the same four
steps, still available individually for debugging a specific stage:

```bash
./scripts/build-app.sh --release
./scripts/sign.sh "Developer ID Application: Teu Teulilo (P523Y49P5B)"
./scripts/make-dmg.sh
./scripts/notarize.sh "build/myKikau-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/myKikau.app/Contents/Info.plist).dmg" \
  "Developer ID Application: Teu Teulilo (P523Y49P5B)"
```

One-time prerequisites (see comments at the top of each script for exact steps):

1. Apple Developer Program membership + a **Developer ID Application** certificate
   in your login keychain.
2. An app-specific Apple ID password, stored once via
   `xcrun notarytool store-credentials`.
3. Add this to `~/.zshrc` so you never have to pass the identity manually:
   ```bash
   export MYKIKAU_SIGN_IDENTITY="Developer ID Application: Teu Teulilo (P523Y49P5B)"
   ```

### Publishing

Upload the stapled DMG to the website's download location and update the Sparkle
`appcast.xml` entry (see `docs/IMPLEMENTATION_PLAN.md` Phase 0.6) so existing
installs pick up the update automatically.

## Contributing

1. Create a branch from `main`
2. Make changes following the safety rules in `AGENTS.md`
3. Run `swift test` to verify
4. Open a PR against `main`

Do not add AI attribution trailers to commits (per `AGENTS.md`).