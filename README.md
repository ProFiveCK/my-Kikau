# myKikau

A native Swift macOS app to replace CleanMyMac — cleanup, uninstaller, disk analyser, live status HUD, and maintenance.

Built for macOS 14+ (Sonoma), fully native Swift. One external dependency: [Sparkle](https://github.com/sparkle-project/Sparkle) for self-updating (direct distribution, not the Mac App Store — see `docs/MODERNIZATION_REVIEW.md` §5).

## Features

- **Clean** — caches, logs, temporary files and Trash, reviewed item by item before anything moves
- **Uninstall** — app inventory, plus each app's leftovers matched by exact bundle ID, in one review sheet; uninstall several at once, and find files left by apps removed earlier
- **Analyse** — disk space explorer with a donut chart, squarified treemap, and sorted list views, folder-by-folder drill-down
- **Duplicates** — content-hash-verified duplicate files (you choose which copy to keep), plus a large-files mode, across Downloads/Documents/Desktop/Pictures/Movies and any folders you add
- **Status** — live CPU / memory / disk / network / battery-health / thermal dashboard + menu bar HUD, with a one-click, cancellable "Scan Everything"
- **Optimise** — 9 bounded, no-sudo maintenance tasks (LaunchServices repair, Finder cache, broken config/plist repair, stale launch agents, etc.), each listing the exact files it will touch
- **Startup** — launch agents and daemons that start in the background; remove your own, see the system-wide ones
- **History** — everything myKikau has done, with Put Back for anything it moved to the Trash
- **Project Purge** — build artifacts (`node_modules`, `target`, `build`, `dist`, `venv`); off by default, enabled with Settings → Advanced → Developer tools

Background scans and low-disk notifications are optional (Settings → General).

## Safety Design

- Single deletion funnel: everything goes to the Trash (Finder-recoverable); only emptying the Trash itself removes for good
- Every plan is reviewed item by item before it runs, and protection is re-checked at the moment of deletion
- Operation log: `~/Library/Logs/myKikau/operations.log` (JSONL, hash-chained so tampering is detectable, rotated at 5 MB)
- Never touched: system paths, keychains, SSH/GPG keys, Mail, Messages, iCloud Drive, security and device-management software, and anything on your exclusion list
- Only rebuildable data is ever a Clean target — never a browser profile, a database or an archive
- Exact bundle-ID evidence for leftovers — no vendor-prefix or generic-name wildcards

## Managed deployment

Installer package, MDM profiles (Full Disk Access, managed settings), audit-log collection and the read-only `mykikau-cli` are covered in [docs/ENTERPRISE_DEPLOYMENT.md](docs/ENTERPRISE_DEPLOYMENT.md).

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