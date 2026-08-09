# Website copy — myKikau download page

*Draft content for whoever builds the download page. Content only — adapt to your site's actual layout/CMS. Replace bracketed placeholders.*

## Hero

**Headline:** Clean, uninstall, and understand your Mac — without giving up control.

**Subhead:** myKikau is a native, from-scratch Mac maintenance app: safe cleanup, leftover-aware uninstalling, duplicate/large-file cleanup, and a live system dashboard. Every deletion goes to the Trash and shows you exactly what it's about to touch before it touches it.

**Primary button:** Download for Mac (Apple Silicon & Intel) — v0.3.0 · 2.8 MB
**Secondary link:** Requires macOS 14 Sonoma or later

## Why myKikau (feature highlights)

- **See it before you delete it.** Every cleanup and uninstall shows a full preview — file paths, sizes, what's protected — before anything moves to the Trash.
- **Uninstall actually means uninstall.** Removes the app, its LaunchAgents, login items, and leftover files across your whole `~/Library` — not just the `.app` bundle.
- **Bounded, safe maintenance.** 10 vetted upkeep tasks — LaunchServices repair, cache refresh, orphaned Spotlight rules, and more — no admin password needed, with an optional preview mode.
- **A real system dashboard.** Live CPU, memory, disk, network, GPU, thermal, and battery — not a marketing gauge, actual native metrics, refreshed every 2 seconds, plus a menu bar HUD.
- **Duplicates & large files.** Content-hash-verified duplicate detection plus a large-files view across Downloads, Documents, Desktop, Pictures, and Movies.
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

### Version 0.3.0 — August 2026

**New**
- Full System Scan now summarizes cleanup, apps, duplicate files, and large files in one dashboard entry point, then opens each module with cached results
- Dashboard CPU and memory cards now open live top-process views without needing to rescan
- Menu bar mode now supports a tray-first workflow with improved status, quick actions, and clearer app identity
- Release tooling now prepares Sparkle appcasts, release notes, and GitHub Releases from one deploy-prep command

**Improved**
- Dashboard simplified: duplicate Quick Actions and the flickering Disk IO card were removed, and module navigation now leans on the colored sidebar
- Disk Analyse now starts from the top-level disk view, keeps the last scan with a timestamp, and makes the map/list views easier to read
- Uninstall adopts Full System Scan app results, highlights large apps unused for 3+ or 6+ months, and removes uninstalled apps from the list immediately
- Optimise now uses clearer visual task cards with per-task status and safer preview language
- Clean and Trash results now clear from the UI after successful removal instead of requiring a fresh scan

**Fixed**
- Local debug app bundles are ad-hoc signed after rpath mutation so macOS no longer kills them for invalid code signatures
- Top CPU and memory process sheets no longer hang when process output fills a pipe
- Memory process results are sorted by resident memory use, matching the CPU sheet's highest-usage-first behavior

*Full changelog: [github.com/ProFiveCK/my-Kikau/releases](https://github.com/ProFiveCK/my-Kikau/releases)*

### Version 0.2.1 — August 2026

**Improved**
- Uninstall now shows a clear "App Uninstalled" (or "with Warnings") popup when it finishes, instead of an easy-to-miss caption
- Clean's app-cache targets (Slack, Discord, Zoom, Dropbox, Teams, Safari, Edge, Brave) now point at their correct, current cache locations

**Fixed**
- Clean's Trash category now actually empties the Trash
- Disk Analyser was undercounting real usage — it was skipping `~/Library` (one of the largest parts of most home folders) from its totals; fixed
- A checkbox-looking icon in the Uninstall review screen — it was never interactive, now reads clearly as "this app will be removed"

*Full changelog: [github.com/ProFiveCK/my-Kikau/releases](https://github.com/ProFiveCK/my-Kikau/releases)*

### Version 0.2.0 — August 2026

**New**
- Status dashboard redesigned as a live "Mac Health" card — storage, memory, battery, and CPU at a glance, with one-click access into Clean
- Disk Analyse gets an interactive donut chart alongside the treemap and list views
- Duplicate and large-file finder, content-hash verified, across Downloads/Documents/Desktop/Pictures/Movies
- One-click "Scan Everything" from the dashboard
- About screen — version, update checks, and your operation log, one click away
- Auto-updates via Sparkle

**Improved**
- GPU usage now reads live, without needing admin privileges
- Network throughput readings fixed
- Optimise trimmed to the 10 maintenance tasks that actually run, each clearly marked safe, with an optional preview mode
- Mac Health score now explains what it's measuring instead of showing a bare number
- Real app icons throughout the Uninstaller

**Fixed**
- Cancel on a delete confirmation could no longer trigger a deletion
- CPU usage reading fixed (was stuck near 0%)
- Fixed a crash on launch in the signed/notarized build (missing embedded framework)

*Full changelog: [github.com/ProFiveCK/my-Kikau/releases](https://github.com/ProFiveCK/my-Kikau/releases)*

## Footer legal line

myKikau is signed and notarized by Apple. © 2026 Project Five. Licensed under GPL-3.0 — [source code](https://github.com/ProFiveCK/my-Kikau).
