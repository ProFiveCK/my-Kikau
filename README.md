# myKikau

A native Swift macOS app to replace CleanMyMac — cleanup, uninstaller, disk analyser, live status HUD, and maintenance.

Built for macOS 14+ (Sonoma), fully native Swift. One external dependency: [Sparkle](https://github.com/sparkle-project/Sparkle) for self-updating (direct distribution, not the Mac App Store — see `docs/MODERNIZATION_REVIEW.md` §5).

## Origin

Logic reimplemented natively in Swift, informed by [Mole](https://github.com/tw93/Mole) (GPL-3.0, Go + Bash CLI). Mole is credited as the source; this project is independent and released under the same license per GPL-3.0 terms.

## Features

- **Clean** — caches, logs, trash, leftovers (browser, dev tools, system, user apps)
- **Uninstall** — app inventory + exact bundle-ID leftover teardown
- **Analyse** — disk space explorer with a donut chart, squarified treemap, and sorted list views, folder-by-folder drill-down
- **Duplicates** — content-hash-verified duplicate files, plus a large-files mode, across Downloads/Documents/Desktop/Pictures/Movies
- **Status** — live CPU / memory / disk / network / battery / thermal dashboard + menu bar HUD, with a one-click "Scan Everything"
- **Optimise** — 10 bounded, no-sudo maintenance tasks (LaunchServices repair, Finder cache, broken config/plist repair, orphaned Spotlight rules, etc.)

Also in the codebase but not exposed in this release: a dev-project-artifact purge scanner (`node_modules`, `target`, `build`, `dist`, `venv`) — see `docs/IMPLEMENTATION_PLAN.md` for why it's held back.

## Safety Design

- Single deletion funnel routes through Trash by default (Finder-recoverable)
- Operation log: `~/Library/Logs/myKikau/operations.log` (JSONL)
- Dry-run preview before every destructive action
- Protected paths and bundle IDs never modified (`/System`, `/Library/Apple`, `com.apple.*` system bundles)
- Exact bundle-ID evidence for leftovers — no vendor-prefix or generic-name wildcards

## Build

```bash
swift build
swift test
```

Build a macOS `.app` bundle with the app icon:

```bash
./scripts/build-app.sh            # debug -> build/myKikau.app
./scripts/build-app.sh --release  # release -> build/myKikau.app
open build/myKikau.app
```

Lint (optional, install once with `brew install swiftformat swiftlint`):

```bash
./scripts/lint.sh        # check
./scripts/lint.sh --fix  # auto-format
```

Open in Xcode for the full app bundle experience (menu bar HUD, App Sandbox, signing):

```bash
open Package.swift
```

For detailed setup, architecture, and safety design, see [docs/SETUP.md](docs/SETUP.md).

## License

GPL-3.0 — see [LICENSE](LICENSE).