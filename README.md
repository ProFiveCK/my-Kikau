# myKikau

A native Swift macOS app to replace CleanMyMac — cleanup, uninstaller, disk analyser, live status HUD, and maintenance.

Built for macOS 14+ (Sonoma), fully native Swift. One external dependency: [Sparkle](https://github.com/sparkle-project/Sparkle) for self-updating (direct distribution, not the Mac App Store — see `docs/MODERNIZATION_REVIEW.md` §5).

## Features

- **Clean** — caches, logs, temporary files and Trash, reviewed item by item before anything moves
- **Uninstall** — app inventory, plus each app's leftovers matched by exact bundle ID, in one review sheet; uninstall several at once, find files left by apps removed earlier, and check for newer versions of installed apps
- **Analyse** — disk space explorer with a donut chart, squarified treemap, and sorted list views, folder-by-folder drill-down
- **Files** — content-hash-verified duplicates (you choose which copy to keep), a large-files mode, and similar-photo detection using on-device image analysis, across Downloads/Documents/Desktop/Pictures/Movies and any folders you add
- **Overview / Care hub** — scan, then review cleanup, applications, files and system care from one shared set of results; live CPU / memory / disk / network / battery / thermal monitoring is available from Live activity and the menu bar
- **Optimise** — 9 bounded, no-sudo maintenance tasks (LaunchServices repair, Finder cache, broken config/plist repair, stale launch agents, etc.), each listing the exact files it will touch
- **Startup** — launch agents and daemons that start in the background; remove your own, see the system-wide ones
- **History** — everything myKikau has done, with per-file Put Back; Trash moves and permanent removals have separate historical totals, while Overview reports current available storage
- **Project Purge** — build artifacts (`node_modules`, `target`, `build`, `dist`, `venv`); off by default, enabled with Settings → Advanced → Developer tools

Scheduled scans are optional (Settings → General). Scans and file changes share one activity guard; cancellation retains ownership until the worker stops. Scan coverage distinguishes checked locations, missing optional folders, cloud-only files and read failures. App update checks report available, up to date, unsupported and failed results separately.

Maintenance inspections produce recommendations, never “Applied” results. Failed, unavailable and skipped checks are shown separately from successful checks. The full scan includes maintenance and startup discovery, so opening those screens uses the results already found.

Older mixed “freed” totals are retained as unclassified historical activity, rather than converted into inaccurate permanent-removal totals. The Care hub offers **Quick scan** (everyday cleanup and startup) and **Full scan** (also applications, duplicate/large files and system care); similar-photo comparison stays on demand in My files. Each area retains its own checked time. Scheduled scans use Quick scan and notify only about its cleanup results.

**History → Cleanup sessions → Review & Restore** previews the exact recorded files from a cleanup, including unavailable and permanently removed items. Restore checks the Trash file identity, protection rules and destination again, skips conflicts, and never overwrites. It restores files, not settings or app services. Sessions share the existing local operation log, including retained rotations; with logging off, no new recovery history is stored. Earlier ungrouped records keep individual Put Back.

## Safety Design

- Single deletion funnel: everything goes to the Trash (Finder-recoverable); only emptying the Trash itself removes for good
- Every plan is reviewed item by item before it runs, and protection is re-checked at the moment of deletion
- Operation log: `~/Library/Logs/myKikau/operations.log` (JSONL, hash-chained so tampering is detectable, rotated at 5 MB)
- Never touched: system paths, keychains, SSH/GPG keys, Mail, Messages, iCloud Drive, security and device-management software, and anything on your exclusion list
- Only rebuildable data is ever a Clean target — never a browser profile, a database or an archive
- Exact bundle-ID evidence for leftovers — no vendor-prefix or generic-name wildcards

## Administrator helper (optional)

Apps installed for all users (App Store, most installer packages) are owned by root, which the app can't remove on its own. Settings → Advanced can install a small privileged helper for that. It needs an administrator's approval in System Settings once and a password each time; it only ever moves specific, policy-checked items into your Trash. See `Sources/Helper/main.swift` and `HelperPolicy.swift`.

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