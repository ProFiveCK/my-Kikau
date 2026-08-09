# myKikau

A native Swift macOS app to replace CleanMyMac — cleanup, uninstaller, disk analyzer, live status HUD, maintenance, and dev artifact purge.

Built for macOS 14+ (Sonoma), fully native Swift, no external binary dependencies.

## Origin

Logic reimplemented natively in Swift, informed by [Mole](https://github.com/tw93/Mole) (GPL-3.0, Go + Bash CLI). Mole is credited as the source; this project is independent and released under the same license per GPL-3.0 terms.

## Features

- **Clean** — caches, logs, trash, leftovers (browser, dev tools, system, user apps)
- **Uninstall** — app inventory + exact bundle-ID leftover teardown
- **Analyze** — disk space explorer with treemap visualization
- **Status** — live CPU / memory / disk / network / battery / thermal dashboard + menu bar HUD
- **Optimize** — bounded maintenance tasks (LaunchServices, Spotlight, DNS, etc.)
- **Purge** — dev project artifacts (node_modules, target, build, dist, venv)

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

Open in Xcode for the full app bundle experience (menu bar HUD, App Sandbox, signing):

```bash
open Package.swift
```

For detailed setup, architecture, and safety design, see [docs/SETUP.md](docs/SETUP.md).

## License

GPL-3.0 — see [LICENSE](LICENSE).