# Release notes — myKikau

*`scripts/prepare-deploy.sh` copies the `### Version <version>` section below into the GitHub release. The /apps/ page itself is part of the Project Five static site (`src/pages.mjs` in `~/MyProjects/projectfive/website-renew/site`); `scripts/deploy-website.py` sets its version and DMG size through that site's `src/mykikau.json`.*

## Release notes

### Version 0.10.4 — October 2026

- **Remove system-wide startup items** — with the administrator helper turned on, System care → Startup items can remove background services installed for all users, such as an app's leftover updater. Each one is stopped straight away, the helper tool it runs is removed with it, and everything goes to the Trash after you approve with an administrator password.
- **Clear limits** — Apple's own items and security or device-management software stay protected, and a helper tool is only removed when the service names that exact file.

### Version 0.10.3 — October 2026

- **A simpler sidebar** — seven places instead of ten. Startup items are now a tab of System care, About is in the app menu, and Network joins Project Purge under Settings → Advanced tools.
- **Calmer System care** — checks with nothing to do are collapsed, only recommendations have a checkbox, and repeated status lines are gone.
- **A clearer Overview** — the headline says what the scan found, and scan times are shown once per area.
- **Faster Storage** — folder sizes are remembered even when a protected folder elsewhere can't be read, so opening a folder no longer measures it again.
- **Lighter on your Mac** — live readings are collected only while Live activity is open, desktop Macs no longer start a helper process every two seconds, and System care opens without reading the whole activity log.
- **Updates from the new website** — the update feed moves to projectfive.co.ck/downloads/appcast.xml.

### Version 0.10.2 — October 2026

- **Clearer Trash failures** — items needing administrator approval now explain how to finish in Finder, with a shortcut to reveal the remaining items. Administrator-owned Trash contents can still require Finder.
- **Build-aware cleanup** — known command-line build and package tools keep developer caches out of cleanup while running. SwiftPM, node-gyp, Clang and Homebrew caches now use the same protection as the other developer caches.
- **Clear Docker coverage** — Clean explains which Mac caches it covers, and that Docker-managed images, containers, volumes and build cache are not included in its totals.
- **Fresh checks before cleanup** — reviews are prepared off the main thread and eligibility is checked again at confirmation. Temporary folders with recently written files at any depth are left alone.
- **Stronger deletion checks** — symlinked Trash parents cannot permit permanent deletion outside Trash, and security-agent descendants added after a scan are checked again before removal.
- **Safer System care** — file-removal tasks require reviewed paths, cancellation stops later steps and rechecks, and newly protected items are reported as skipped.

### Version 0.10.1 — October 2026

- **Settings opens in front** — the menu-bar shortcut activates myKikau, dismisses its popover and focuses the native Settings window, including when the Dock icon is hidden or Settings was minimized.
- **Consistent Settings layout** — the menu-bar and main-app shortcuts use the same Settings scene, with its own typography, controls and constrained window sizing. All four sections remain available and their forms scroll.

### Version 0.10.0 — October 2026

- **A consistent Care experience** — refreshed cleanup, applications, files, storage, network, system care, startup, purge and history screens share the Care hub’s cards, typography and primary actions.
- **Original myKikau branding** — the green-and-gold app icon appears consistently in the sidebar, menu-bar companion, Settings, onboarding and review dialogs.
- **A clearer menu-bar companion** — live metric drill-downs, application and system-care shortcuts, active-task progress and cancellation, plus convenient Settings and Quit controls.
- **Review Trash before removal** — the menu-bar shortcut opens an exact-item review in the main window, with a second confirmation for permanent deletion. Preparing a review changes no files.
- **Light, dark and compact layouts** — adaptive colors, responsive headers, readable result panels and Settings sections that stay visible while forms scroll.

### Version 0.9.1 — October 2026

- The sidebar now displays myKikau’s original green-and-gold app icon.
- Overview uses a home icon in place of the sparkle symbol.

### Version 0.9.0 — October 2026

- **Care hub** — a new overview with cleanup, applications, files, system care, disk space and a separate Live activity panel, in light and dark appearances.
- **Quick and Full scans** — everyday cleanup and startup checks, or thorough discovery including duplicate comparisons and system care. Each area shows when it was checked; similar-photo analysis remains on demand.
- **Cleanup session recovery** — review the exact recorded files from a cleanup and restore selected files still in the Trash. Identity, protection and destination checks prevent restoring a replacement file or overwriting current work. Settings and app services are not restored.
- **Privacy information** — normal denied Local Network permissions and stale application paths are informational. Ignore an exact observation persistently, or restore it to the list; changed records reappear.
- **Clearer results** — separate Trash and permanent-removal totals, explicit unsupported/failed update checks, maintenance recommendations, and readable scan coverage and permission gaps.
- **One task at a time** — shared cancellation and operation ownership prevent overlapping scans, cleanup and restore operations.

### Version 0.8.0 — October 2026

**New**
- Review sheet rebuilt: every item has a checkbox, the button says exactly what will happen ("Move 12 Items to Trash"), you see progress with a Cancel button, and a result page lists anything that couldn't be removed and why
- **History** — everything myKikau has done, with **Put Back** for anything it moved to the Trash, export to CSV, and a log integrity check
- **Startup Items** — see the launch agents and daemons that start in the background, and remove your own
- Uninstall several apps at once, and **Find Leftovers** left behind by apps you removed earlier
- **Check for Updates** in Apps asks each app's own update feed, and the App Store, for newer versions — then opens the app or its store page; nothing is installed for you
- **Similar Photos** in Files groups pictures that look alike — resized copies, re-saved exports, burst shots — analysed on your Mac
- The Apps list is a proper table: click a column to sort by name, last used or size
- Choose which copy to keep in each set of duplicates; add your own folders to the Files scan; set the large-file size
- Settings gains a **Never Remove** list, background scans with a notification when there's enough to reclaim, and a low-disk alert
- Battery health and cycle count, and CPU / memory trend lines, on the dashboard
- For managed Macs: MDM-controlled settings, a pre-approval profile for Full Disk Access, and a read-only `mykikau-cli` for fleet reporting
- Optional **administrator helper** (Settings → Advanced): lets Uninstall remove apps that were installed for all users — App Store apps, installer packages — after an administrator password. It only ever moves specific, checked items to your Trash

**Safer**
- Clean only ever targets data an app rebuilds by itself. Browser profiles, Xcode Archives and the temp folder itself are no longer targets; caches of apps that are open are skipped
- Keychains, SSH keys, Mail, Messages, iCloud Drive and security software are protected everywhere, and protection is checked again at the moment of deletion
- Leftover matching is exact: uninstalling an app can no longer select a sibling app's files (Chrome vs Chrome Canary), and a second installed copy keeps its data
- Duplicates are re-checked on disk before anything is queued; files stored only in iCloud are skipped instead of being downloaded
- Two Optimise tasks that edited live system data (download quarantine history, Spotlight rules) were removed; Optimise now lists the exact files a fix will touch

**Improved**
- Scans show progress and can be cancelled; results stay when you switch screens
- The dashboard no longer starts a helper process every two seconds; memory pressure now matches Activity Monitor
- Disk Analyser remembers folder sizes, so drilling in is instant
- Keyboard: ⌘1–⌘9 to switch screens, ⌘R to rescan. The sidebar is grouped and reopens where you left off
- VoiceOver labels throughout

**Fixed**
- Uninstall could report a login item as removed when macOS had refused the request
- After Optimise applied fixes, the screen still listed them as issues
- Project Purge never found dot-named folders such as `.build` and `.venv`

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
