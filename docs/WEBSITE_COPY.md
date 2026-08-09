# Website copy — myKikau download page

*Draft content for whoever builds the download page. Content only — adapt to your site's actual layout/CMS. Replace bracketed placeholders.*

## Hero

**Headline:** Clean, uninstall, and understand your Mac — without giving up control.

**Subhead:** myKikau is a native, from-scratch Mac maintenance app: safe cleanup, leftover-aware uninstalling, dev-project purging, and a live system dashboard. Every deletion goes to the Trash and shows you exactly what it's about to touch before it touches it.

**Primary button:** Download for Mac (Apple Silicon & Intel) — v0.2.0 · 1.8 MB
**Secondary link:** Requires macOS 14 Sonoma or later

## Why myKikau (feature highlights)

- **See it before you delete it.** Every cleanup and uninstall shows a full preview — file paths, sizes, what's protected — before anything moves to the Trash.
- **Uninstall actually means uninstall.** Removes the app, its LaunchAgents, login items, and leftover files across your whole `~/Library` — not just the `.app` bundle.
- **A real system dashboard.** Live CPU, memory, disk, network, GPU, thermal, and battery — not a marketing gauge, actual native metrics, refreshed every 2 seconds, plus a menu bar HUD.
- **Nothing hidden.** Every action is logged locally (`~/Library/Logs/myKikau/operations.log`) so you can see exactly what ran and when.

## Trust / safety section

myKikau never touches macOS system files, and protects ~90 critical Apple bundle IDs (Finder, Dock, System Settings, and more) from accidental removal — including apps you didn't even know were protected. It also recognises and skips endpoint-security agents (CrowdStrike, SentinelOne, Jamf, and others) so it won't trip tamper detection on managed Macs.

Full Disk Access is requested on first launch and explained plainly — myKikau needs it to see other apps' caches and leftovers, the same as any Mac cleaner. You can grant it later from Settings if you skip it initially.

## System requirements

- macOS 14 (Sonoma) or later — Apple Silicon or Intel
- ~2 MB disk space (installer download)
- Full Disk Access permission (requested on first launch; some features are limited without it)

## Open source

myKikau's source is public and licensed under GPL-3.0.
**Source code:** github.com/ProFiveCK/my-Kikau

## Release notes (template — duplicate per version)

### Version 0.2.0 — August 2026

**New**
- Status dashboard is now the home screen, with quick-launch cards into every module and a one-click "Scan Everything"
- Duplicate and large-file finder (content-hash verified)
- Visual storage map (treemap) in Analyse
- Auto-updates via Sparkle

**Improved**
- Per-module accent colors and live sparklines on system stats
- Menu bar HUD gains quick actions (Empty Trash, Open Clean)
- Real app icons throughout the Uninstaller

**Fixed**
- Cancel on a delete confirmation could not trigger a deletion

*Full changelog: [github.com/ProFiveCK/my-Kikau/releases](https://github.com/ProFiveCK/my-Kikau/releases)*

## Footer legal line

myKikau is signed and notarized by Apple. © 2026 Project Five. Licensed under GPL-3.0 — [source code](https://github.com/ProFiveCK/my-Kikau).
