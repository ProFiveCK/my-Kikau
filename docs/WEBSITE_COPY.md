# Website copy — myKikau download page

*Draft content for whoever builds the download page. Content only — adapt to your site's actual layout/CMS. Replace bracketed placeholders.*

## Hero

**Headline:** Clean, uninstall, and understand your Mac — without giving up control.

**Subhead:** myKikau is a native, from-scratch Mac maintenance app: safe cleanup, leftover-aware uninstalling, duplicate/large-file cleanup, and a live system dashboard. Every deletion goes to the Trash and shows you exactly what it's about to touch before it touches it.

**Primary button:** Download for Mac (Apple Silicon & Intel) — v0.7.0 · 3.1 MB
**Secondary link:** Requires macOS 14 Sonoma or later

## Why myKikau (feature highlights)

- **See it before you delete it.** Every cleanup and uninstall shows a full preview — file paths, sizes, what's protected — before anything moves to the Trash.
- **Uninstall actually means uninstall.** Removes the app, its LaunchAgents, login items, and leftover files across your whole `~/Library` — not just the `.app` bundle.
- **Bounded, safe maintenance.** 12 vetted upkeep tasks — LaunchServices repair, cache refresh, font cache reset, orphaned Spotlight rules, and more — no admin password needed, with an optional preview mode.
- **A real system dashboard.** Live CPU, memory, disk, network, GPU, thermal, and battery — not a marketing gauge, actual native metrics, refreshed every 2 seconds, plus a menu bar HUD.
- **Duplicates & large files.** Content-hash-verified duplicate detection plus a large-files view across Downloads, Documents, Desktop, Pictures, and Movies.
- **Nothing hidden.** Every action is logged locally (`~/Library/Logs/myKikau/operations.log`) so you can see exactly what ran and when.

## Trust / safety section

myKikau never touches macOS system files, and protects ~90 critical Apple bundle IDs (Finder, Dock, System Settings, and more) from accidental removal — including apps you didn't even know were protected. It also recognises and skips endpoint-security agents (CrowdStrike, SentinelOne, Jamf, and others) so it won't trip tamper detection on managed Macs.

Full Disk Access is requested on first launch and explained plainly — myKikau needs it to see other apps' caches and leftovers, the same as any Mac cleaner. You can grant it later from Settings if you skip it initially.

## System requirements

- macOS 14 (Sonoma) or later — Apple Silicon or Intel
- ~3 MB disk space (installer download)
- Full Disk Access permission (requested on first launch; some features are limited without it)

## Open source

myKikau's source is public and licensed under GPL-3.0.
**Source code:** github.com/ProFiveCK/my-Kikau

## Release notes (template — duplicate per version)

### Version 0.7.0 — August 2026

**New**
- Network screen — connection details (interface, local IP, subnet, router, DNS, MAC) and a full Wi‑Fi radio readout: network name, band, channel and width, protocol, security, transmit rate, and signal/SNR
- On-demand public-IP lookup, and one-click **Flush DNS Cache** / **Renew DHCP Lease** that run with a single macOS password prompt — no Terminal
- The menu bar HUD now shows your connection and local IP address, with one-tap copy
- Optimise gains a **Font Cache Reset** task — fixes garbled or missing text in apps, no admin password needed

**Improved**
- Disk Analyser opens on a whole-disk overview — used vs free space, the folders using the most storage, and a computed "macOS System" figure that adds up to your drive's full capacity — instead of starting in your home folder
- Disk Analyser navigation redesigned: a Finder-style path bar you can click at any level, plus an Up button, replacing the single Back button
- Hidden dot-folders (`.cache`, `.npm`, and the like) now appear as their own rows you can open, with a header toggle to hide them again — instead of one lumped-together "Hidden Items" total you couldn't drill into

**Fixed**
- Menu bar Quick Actions no longer show a "View Memory Users" button that just repeated the Memory row directly above it

### Version 0.6.1 — August 2026

**Fixed**
- Apps list was missing applications installed in a vendor subfolder under /Applications (e.g. Adobe Acrobat, OpenVPN Connect) instead of directly in it
- The Apps search field could fail to accept keystrokes
- Dashboard summary cards could go stale after uninstalling an app or removing duplicate/large files elsewhere in the app, until a manual Rescan
- Duplicate and Large File scans could silently report nothing found when macOS hadn't granted Desktop/Documents/Downloads access — now clearly flagged with a direct link to fix it
- Top Memory Processes figures now match Activity Monitor's "Memory" column exactly, instead of a raw resident-memory reading that ran noticeably higher
- Clean/Apps/Files review sheets now sort by size, largest first
- Opening the Dashboard from the menu bar could also pop open the Settings window

**Improved**
- CPU and Memory rows in the menu bar HUD now open straight to their Top Processes view; Disk opens the Disk Analyser
- Dashboard's Network card replaced with a compact tile inside the Mac Health card; Duplicates and Large Files summaries merged into one Files summary

### Version 0.6.0 — August 2026

**New**
- System Health audit for macOS Local Network privacy residuals — surfaces stale Local Network privacy entries left behind by uninstalled apps so you can review and clean them up

### Version 0.5.1 — August 2026

**New**
- A real Settings window (⌘,) with a Launch at Login toggle — myKikau can now start automatically without a third-party login-item tool
- Apps list gains search and sort (by size, name, or last used)
- Clean gets a "Review All" action to confirm every cleanup category in one pass instead of one at a time

**Improved**
- Optimise no longer always flags Cache Refresh and LaunchServices Repair as needing attention — they're now recommended only when actually due
- Mac Health card's status wording and color now always agree with each other
- Top Processes can be quit from either the CPU or Memory view, not just Memory

**Fixed**
- A dashboard navigation flag could silently stop working if touched during a refactor; replaced with a type-safe version

### Version 0.5.0 — August 2026

**New**
- Live GPU utilisation and CPU temperature are now available in both the main dashboard and menu bar HUD
- Analyse scans can be reused across views, so moving between disk tools no longer means starting over

**Improved**
- Dashboard cards, metric details, and window navigation were redesigned for a clearer at-a-glance view without duplicate windows
- Optimise now groups maintenance tasks more clearly and gives stronger preview, progress, and completion feedback
- Apps and Analyse workflows have clearer empty states, actions, and scan-result presentation

**Fixed**
- Opening myKikau from the menu bar now reuses and focuses the existing main window instead of creating duplicates

### Version 0.4.3 — August 2026

**Improved**
- Menu bar icon redesigned as a custom monochrome vector glyph (bundled PDF) that renders correctly in the system tray across light and dark menu bar themes
- Teal accent dot appears on the menu bar icon when a Full System Scan finds 500MB+ of reclaimable space
- Menu bar icon now uses `.renderingMode(.template)` to reliably follow the system menu bar colour

### Version 0.4.2 — August 2026

**Fixed**
- Menu bar icon replaced with a proper SF Symbol (`internaldrive`) that renders correctly in the system tray — the previous template-image approach produced a white square from the full-colour app icon

### Version 0.4.1 — August 2026

**Improved**
- Menu bar icon now renders in the system menu bar colour (white in dark mode, black in light mode) to blend with other system tray icons
- Removed several force-unwrap crash risks across the formatter, URL handling, and log paths
- Removed dead code and debug print statements from production builds
- Extracted hardcoded UserDefaults keys into a shared constants enum

**Fixed**
- Sparkle appcast no longer references delta update files that were never uploaded to the server, eliminating 404 errors during update checks

*Full changelog: [github.com/ProFiveCK/my-Kikau/releases](https://github.com/ProFiveCK/my-Kikau/releases)*

### Version 0.4.0 — August 2026

**Improved**
- Memory workflow: the menu bar HUD and dashboard now offer a clearer "Free Inactive Memory" action when the purge tool is available, and fall back to "View Memory Users" when it isn't
- Tray navigation: the menu bar HUD's quick actions now reliably open the main window and navigate to the correct screen
- Memory optimiser now returns a clear message when the purge tool isn't available on the current macOS version

*Full changelog: [github.com/ProFiveCK/my-Kikau/releases](https://github.com/ProFiveCK/my-Kikau/releases)*

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
