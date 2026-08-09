# myKikau — Implementation Plan

*Direct-to-website distribution, not Mac App Store. Companion to `docs/MODERNIZATION_REVIEW.md` — that doc explains the "why," this one is the sequenced backlog.*

Each task has an ID, effort size (**S** = under an hour, **M** = a session, **L** = multi-session, **XL** = its own mini-project), the files it touches, and what "done" looks like. Tasks marked **[YOU]** need something only you can provide (an Apple account, a domain, a decision) — everything else is implementable directly.

---

## Phase 0 — Release infrastructure (blocks any public download)

| ID | Task | Effort | Status |
|---|---|---|---|
| 0.1 | **[YOU]** Confirm/enroll in the Apple Developer Program ($99/yr) and generate a **Developer ID Application** certificate in Xcode or developer.apple.com | — | ⏳ **On you** — blocks 0.2–0.4 actually running (the scripts are written and waiting for a certificate identity). |
| 0.2 | `myKikau.entitlements` (hardened runtime, no App Sandbox) + `scripts/sign.sh` | S | ✅ **Done** — `codesign --options runtime`, verifies + Gatekeeper dry-run. |
| 0.3 | `scripts/notarize.sh` — signs the DMG, `notarytool submit --wait`, `stapler staple` | S | ✅ **Done**. One-time `notarytool store-credentials` setup is **[YOU]** (instructions in the script header). |
| 0.4 | `scripts/make-dmg.sh` — drag-to-Applications DMG, version read from `Info.plist` | S | ✅ **Done**. |
| 0.5 | Versioning convention + release process | S | ✅ **Done** — documented in `docs/SETUP.md` under "Release Process." |
| 0.6 | Sparkle auto-update integration | M | ✅ **Done** — see below. |
| 0.7 | First-launch onboarding + Full Disk Access | M | ✅ **Done** — see below (design changed from what was originally planned; noted). |
| 0.8 | Website download page copy + release notes template | S | ✅ **Done** — `docs/WEBSITE_COPY.md`, adapt to your actual site. |
| 0.9 | GPL-3.0 source-code link for the download page | S | ✅ **Done** — included in `docs/WEBSITE_COPY.md`'s footer copy. |

**0.6 detail — Sparkle:** added as an SPM dependency (`Package.swift`, floor `2.9.0`), wired via `Sources/App/Updater.swift` (`SPUStandardUpdaterController` + a "Check for Updates…" menu command in `myKikauApp.swift`). `Info.plist` has placeholder `SUFeedURL`/`SUPublicEDKey` that **must be replaced** before shipping — `appcast.xml.template` shows the feed shape, and `scripts/update-appcast.sh` wraps Sparkle's own `generate_appcast` tool to build the real feed from a folder of release DMGs.

**0.7 detail — onboarding, and a course-correction:** the original plan said to wire the existing `Permissions.swift` (security-scoped bookmarks) into onboarding. Implementing it surfaced a mismatch: security-scoped bookmarks are an **App Sandbox** mechanism, and Phase 0 explicitly decided *against* sandboxing (direct distribution needs the broader access sandboxing blocks). For an unsandboxed app, the actual gate is **Full Disk Access**, a system-wide TCC grant, not per-URL bookmarks. So instead: added `Sources/Core/FullDiskAccessCheck.swift` (a best-effort FDA probe — there's no public API for this, so it checks whether a couple of known FDA-gated paths are readable), `Sources/App/OnboardingView.swift` (shown once via `RootView` in `myKikauApp.swift`, links straight to System Settings), and a persistent reminder banner on `StatusView` for anyone who skips it. `Permissions.swift` itself is unchanged — it's the right tool if this ever grows a sandboxed build variant, just not the one this distribution path uses.

**Phase 0 exit criteria:** once 0.1 is done, `scripts/build-app.sh --release && scripts/sign.sh "<identity>" && scripts/make-dmg.sh && scripts/notarize.sh build/myKikau-X.Y.Z.dmg "<identity>"` produces a DMG that installs and opens cleanly on a clean Mac with Gatekeeper on. Sparkle won't actually find updates until `SUFeedURL`/`SUPublicEDKey` are filled in and an `appcast.xml` is hosted at that URL.

---

## Phase 1 — Correctness cleanup

| ID | Task | Effort | Status |
|---|---|---|---|
| 1.1 | Fix Cancel-button-deletes-files bug in `PlanReviewView` | S | ✅ **Done** |
| 1.2 | Status as landing screen + dashboard hub with Quick Actions grid | M | ✅ **Done** |
| 1.3 | Real app icons in Uninstaller via `NSWorkspace` | S | ✅ **Done** |
| 1.4 | README claimed "disk space explorer with **treemap visualization**" — no treemap existed in the code at the time | S | ✅ **Done**, twice over — README was corrected first, then 3.3 shipped the actual treemap, so the claim is true again. |
| 1.5 | Sort `AnalyzeView` entries largest-first | S | ✅ **Already true** — `DiskScanner.scan` already sorts descending by size; the original review missed this. No change needed. |
| 1.6 | Visible selection state in `PurgeView` | S | ✅ **Done** — checkmark + tinted row background on tap. |

---

## Phase 2 — Visual modernization pass

This is the bulk of the "make it look convincing" work. All pure UI, no new subsystems.

| ID | Task | Effort | Status |
|---|---|---|---|
| 2.1 | Per-module accent color carried from the dashboard into each screen's own header/buttons (Clean=blue, Uninstall=purple, Analyze=teal, Optimize=orange, Purge=brown) | M | ✅ **Done** — `tint` added to `ContentView.SidebarItem` as the single source of truth; Quick Actions cards and each of the 5 module screens (header icon + primary button) now pull from it. |
| 2.2 | Sparkline the last samples of CPU/memory on the Status cards | M | ✅ **Done** — hand-rolled `Path`-based sparkline (no new dependency), fed by `MetricsService.history` (60-sample rolling buffer, ~2 min at the 2s poll interval). |
| 2.3 | Menu bar HUD gets action buttons instead of being read-only | S | ✅ **Done**, but scoped down from the original idea — see note below. |
| 2.4 | Consolidate `MetricsCollector` polling — `StatusView` and `HUDView` each ran independent 2s timers | M | ✅ **Done** — `Sources/Features/Status/MetricsService.swift`, a reference-counted single-timer `ObservableObject` both views now subscribe to. |

**2.3 detail — why "Free Up Memory" isn't one of the buttons:** macOS doesn't expose a real, non-placebo way for a normal app to force-free system memory (the underlying `purge` command needs admin, and Apple's own guidance is that manual RAM-purging tools are mostly theater — the VM system already manages this better than a button can). Given the app's actual differentiator is the safety/trust story, shipping a placebo button felt wrong. Implemented **Empty Trash…** instead (confirms via a native alert showing item count + size, then routes through the same `SafeFileDeleter` funnel every other delete in the app uses — mode `.permanent` since it's already-trashed content) and **Open Clean…** (jumps the main window straight to the Clean screen via a small `AppNavigation` relay, since the HUD is a separate SwiftUI scene from the main window).

---

## Phase 3 — Feature gaps vs. CleanMyMac

| ID | Task | Effort | Status |
|---|---|---|---|
| 3.1 | "Scan Everything" dashboard action — runs Clean + Purge scans together, surfaces one combined reclaimable number on Status | M | ✅ **Done** — `Sources/Features/Status/ScanEverythingCoordinator.swift`. Deliberately excludes Uninstall (per-app, user-directed) and Analyze (browse-only, no deletion plan). `CleanView`/`PurgeView` now adopt the cached scan on appear instead of forcing a rescan when you navigate in from the dashboard. |
| 3.2 | Duplicate / large-file finder across the home directory (My Clutter equivalent) | L | ✅ **Done** — `Sources/Features/Duplicates/DuplicateFinder.swift` + new `DuplicatesView`/sidebar item. See detail below. |
| 3.3 | Visual storage map (treemap) for Analyze — delivers on the README's claim | L | ✅ **Done** — hand-rolled squarified treemap (`Sources/UI/Components/SquarifiedTreemap.swift` + `TreemapView.swift`, no new dependency). `AnalyzeView` has a Map/List toggle, defaulting to Map; tapping a folder cell drills in exactly like the list did. |

**3.2 detail:** new `Duplicates` sidebar item (pink tint, `doc.on.doc`), scoped deliberately to Downloads/Documents/Desktop/Pictures/Movies — the user's own content, not `~/Library` or app data (Clean/Purge already own that). Two modes in one screen: **Duplicates** buckets files by exact size first, then confirms true content matches with a streamed SHA-256 (CryptoKit — no new dependency, it's a system framework) so nothing gets hashed unless something else already shares its exact size; each group suggests keeping the most recently modified copy. **Large Files** is the simple sort-by-size mode (≥100 MB, no hashing) with explicit per-file selection before review, since a large file isn't inherently junk the way a duplicate is. Both funnel through the existing `SafeFileDeleter`/`PlanReviewView` flow — added two new `SafeFileDeleter.Category` cases (`duplicate`, `largeFile`) rather than a separate deletion path.

---

## Phase 4 — Roadmap (post-initial-release, not scoped or scheduled)

| ID | Task | Effort | Notes |
|---|---|---|---|
| 4.1 | Malware/Protection scanning module | XL | Biggest remaining feature gap vs. CleanMyMac, but real scope: signature/heuristic sourcing, false-positive risk, ongoing maintenance burden. Needs its own dedicated scoping conversation before any implementation starts. |
| 4.2 | Cloud storage cleanup (iCloud/Google Drive/OneDrive) | L | Niche vs. 4.1; low priority unless you hear demand for it. |

**Status: confirmed migrated to roadmap, decoupled from initial release (per your request).** Neither item is scoped, scheduled, started, or blocking v0.2/v0.3 in any way — no code, no design, no dependency footprint exists for either yet. They stay listed here only so the idea isn't lost, not as a commitment. Revisit only when you decide to open a dedicated scoping conversation for one of them.

---

## Suggested milestones

- **v0.2 "Direct Distribution Launch"** — Phase 0 (all) + Phase 1 (all) + Phase 2 (all). ✅ **All code-side work for this milestone is done.** This is the minimum bar for a public download link: signed, notarized, updates itself, doesn't have a bug where Cancel deletes files, doesn't claim a feature (treemap) that doesn't exist, and looks intentionally designed rather than default-SwiftUI. What's outstanding is entirely on your side — see below.
- **v0.3** — Phase 3 (all). ✅ **Also done.** This is where it starts to feel like a real CleanMyMac competitor rather than "very solid CLI tool wearing a SwiftUI window" — one-click combined scan on the dashboard, a real treemap in Analyze, and a Duplicates/Large Files screen.
- **v0.4+** — a separate scoping pass for Phase 4 (malware/protection scanning, cloud cleanup). Nothing else is queued up right now.

---

## What's left before this can actually ship

All Phase 0–3 code is done — that's the entire initial release scope. Phase 4 (malware/protection scanning, cloud cleanup) is intentionally not part of it; see "Roadmap vs. initial release" below. What's left to actually cut a release is entirely **[YOU]** — none of it is something I can do from here, and two of them (certificate, private key) genuinely shouldn't be handed to me:

0. **Version bumped to `0.2.0`** (`CFBundleShortVersionString`) / build `2` (`CFBundleVersion`) in `Info.plist`, matching the v0.2 milestone. ✅ **Done.**
1. **Developer ID cert (0.1).** ✅ **Done.** `./scripts/sign.sh` ran successfully with `"Developer ID Application: Teu Teulilo (P523Y49P5B)"`; `make-dmg.sh` and `notarize.sh` completed too.
2. **Sparkle EdDSA keypair.** ✅ **Done.** Public key `2kThk3D7f9IzQZOZxdyAV554R0X7NHbpdWdutkbO0p4=` is now in `Info.plist`'s `SUPublicEDKey`. Private key stays in your login keychain, as designed.
3. **Hosting confirmed** — `https://www.projectfive.co.ck/apps/` is wired into `Info.plist`'s `SUFeedURL` and `appcast.xml.template`. Next: run `scripts/update-appcast.sh` to generate the real `appcast.xml` from the (rebuilt) DMG and upload both to that URL.
4. **Download page** — `docs/WEBSITE_COPY.md` and `docs/download-page-mockup.html` are ready whenever you want help dropping it into the actual page at `/apps/`.

**Bug found on the first real install (2026-08-09):** the notarized `build/myKikau-0.2.0.dmg` from the first pipeline run crashes instantly on launch — `Library not loaded: @rpath/Sparkle.framework`. Root cause: `scripts/build-app.sh` copied the bare executable into the `.app` bundle but never embedded `Sparkle.framework` (a binary xcframework dependency) into `Contents/Frameworks/`, and the executable had no rpath pointing there. Works fine under `swift run`/Xcode because SwiftPM can resolve it from `.build` in that context — only a manually-assembled `.app` bundle needs it embedded explicitly. **Fixed** in `scripts/build-app.sh`: it now locates the resolved `Sparkle.framework` under `.build`, copies it into `Contents/Frameworks/`, and adds the `@executable_path/../Frameworks` rpath via `install_name_tool` if missing. `scripts/sign.sh` already used `codesign --deep`, so no change was needed there — it'll pick up and sign the embedded framework automatically. **The whole pipeline needs to be rerun** (`build-app.sh --release` → `sign.sh` → `make-dmg.sh` → `notarize.sh`) to produce a working DMG; the existing `build/myKikau-0.2.0.dmg` should be discarded/not published.

**Remaining to actually ship:** rerun the build→sign→dmg→notarize pipeline with the fix, confirm the app actually launches this time, then upload the DMG + generated `appcast.xml` to `/apps/` on the website and publish the download page.

---

## Phase 5 — First real-install feedback (2026-08-09)

Testing the actual signed build surfaced several issues, all fixed:

- **CPU usage always ~0%.** `MetricsCollector.collectCPU()` wrapped `host_cpu_load_info` in an `Optional` and reinterpreted *that* pointer's raw memory as the C struct — Swift doesn't guarantee `Optional<T>` has the same layout as `T`, so `host_statistics` was writing into the wrong offsets. Fixed by using a plain zero-initialized (non-Optional) struct.
- **Health score showed a bare "100"** with no context, and the dashboard overall read as generic/default-SwiftUI next to CleanMyMac's own widget (user shared a screenshot of it: dark gradient hero card, "Mac Health: Good," glass tiles for Storage/Memory/Battery/CPU, a recommendation card). Replaced the old plain `HealthBanner` with `HeroHealthCard` — a purple gradient hero card with the health score headline plus a glass-tile grid (Storage free space with a "Free Up" link into Clean, Memory % used, Battery, CPU load/temp) and live network throughput, matching that visual ambition instead of just adding a caption to the old flat banner.
- **GPU showed "N/A"** with no explanation. This is real macOS behaviour, not a bug — live GPU usage needs `powermetrics`, which requires root — but the UI now says so instead of leaving it unexplained.
- **Purge removed from this release** (user decision) — niche developer feature, confusing without more explanation than the dashboard has room for. Sidebar entry, Quick Actions card, and Scan Everything's Purge button are hidden; the scanner code and view are untouched for a future release (`SidebarItem.purge` stays defined, just excluded from `SidebarItem.visibleCases`).
- **Spelling pass (NZ/AU convention)** across app UI, docs, and website copy: Analyze→Analyse, Optimize→Optimise, Optimization→Optimisation, recognizes→recognises, favorites→favourites, etc. Internal Swift identifiers and real file paths (e.g. `Sources/Features/Analyze/`) were left as-is — only user-visible text and prose changed.
- **Treemap cells showed as unlabeled colored blocks** ("just divisions") — the label-visibility threshold in `TreemapCell` was too strict for a typical home-folder scan. Lowered, plus wider color range so cells read as distinct instead of a flat gradient.
- **Clean module and Analyze's List view still read as plain system lists** despite the Phase 2 tint pass — added card-style rows with size bars for visual parity with Status/Uninstall.
- **Optimize task safety was unclear.** `MaintenanceCatalog.Task.safeForAuto` existed in the data model already but was never shown in the UI, and the "Dry Run" toggle had no inline explanation. Both are now surfaced.
- **Optimize looked broken — "Run" did nothing, sudo-locked rows always said "skipped."** Turned out about half the catalog (11 of 21 defined tasks) were dispatch stubs that were never actually implemented: 7 sudo-gated tasks always returned `.skipped("Requires sudo — not implemented")`, 4 more always returned `.unavailable(...)`. `MaintenanceCatalog.tasks` (the UI-facing list) now only lists the 10 tasks that actually do something; `MaintenanceRunner`'s dispatch cases for the other 11 are untouched, ready to wire up for real later (sudo tasks need a privilege-escalation UX; the deferred four need an active-app-safety check). Also flipped Optimize's Dry Run default to off — every remaining task is bounded/reversible, so defaulting to a preview that changes nothing made "Run Selected" feel non-functional on first use. The toggle itself stays as an opt-in rather than being removed outright.
- **Network showed a persistent 0.00 MB/s — confirmed as a real bug, fixed.** Got the actual `netstat -ib` output from the user's Mac: real columns are `Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll`, not the 6-column `Name Mtu Network Address Ibytes Obytes` the code assumed. It was reading `Ipkts` (packet count) as bytes-in and `Ierrs` (error count, always 0 on a healthy interface) as bytes-out — upload was permanently stuck at 0 for that reason, download showed a real but minuscule number that rounded to "0.00" at display precision. Fixed `parseByteFields` to read the correct indices (Ibytes=6, Obytes=9) and updated `StatusMetricsTests` to use a realistic 11-column fixture instead of the fictional 6-column one it was written against.
- **History replaced with About.** A raw operation-log list wasn't a useful sidebar destination on its own ("history is useless here"). Added `Sources/App/AboutView.swift` — icon, version/build, Check for Updates (reuses the existing `UpdaterViewModel`, now injected via `.environmentObject` from `myKikauApp`), source link, license, Mole attribution, and a "Reveal Log File" button so the operation log itself (a real safety/trust feature) is still one click away instead of gone. Same reversible pattern as Purge: `SidebarItem.history` stays defined, `HistoryView` is untouched, just excluded from `visibleCases`.
- **Analyse got a third view: Chart (donut), now the default.** The treemap's color gradient wasn't reading as distinct even after widening it — user flagged the same screenshot looked unchanged and asked for a pie chart instead. Added `PieChartSection` using Swift Charts' `SectorMark` (macOS 14+, so no new dependency) — a real donut chart with a categorical color palette, center total, and a tappable legend list for drill-down (legend taps rather than chart hit-testing, to keep the interaction as reliable as Map/List). Map and List are still there via the view picker.
- **GPU usage now works without root.** Was calling `powermetrics` (root-only) and always landing on -1/"N/A" for a normal unprivileged app. Added `GPUMonitor.captureGPUUsageViaIOKit()`, which reads live utilization straight from IORegistry's `IOAccelerator` `PerformanceStatistics` — the same mechanism menu-bar monitors like Stats/iStat Menus use, no elevated privileges needed. `powermetrics` stays as a fallback. Couldn't compile-verify this locally (no macOS toolchain here); if the IORegistry key name doesn't match on this Mac/macOS combination it falls back to the existing N/A behavior rather than showing a wrong number, so worst case is no regression.
- **Mac Health context got dropped in the hero redesign.** The old `HealthBanner`'s explanatory caption and itemized issues list didn't carry over to `HeroHealthCard`. Added back: a "combines CPU load, memory pressure, disk space, temperature & battery wear" caption, plus the issues list (e.g. "High CPU, Heavy Disk IO") when the score isn't a clean 100.

### Second real-install pass (2026-08-09, continued)

- **Clean module's Trash category didn't actually empty the Trash.** `CleanScanner.targets(for: .trash)` treated `~/.Trash` as one single item, and `CleanView` always executed with `mode: .trash` (move-to-Trash) — so "Empty Trash" was really trying to move the already-trashed `.Trash` folder into the Trash, a meaningless operation macOS just no-ops or rejects. Fixed at two points: `CleanScanner` now lists the individual *contents* of `.Trash` as separate items, and `SafeFileDeleter.execute()` now forces any item with `category == .trash` to `.permanent` deletion regardless of what mode the caller asked for, since permanently deleting something already in the Trash is the only operation that makes sense.
- **Uninstall completion feedback was too easy to miss.** The only signal at the end of an uninstall was a small caption at the bottom of the app list (e.g. "1 failed"), easy to miss entirely. Added a proper `.alert` popup in `UninstallView` — titled "App Uninstalled," "Uninstalled with Warnings" (if any teardown/leftover items failed), or "Preview Complete" (dry run), with a message summarizing what happened and how much space was freed.
- **Uninstall's plan-review row had a misleading icon.** The row next to an app pending removal used SF Symbol `"app"` — an empty rounded-square outline that, at that size, reads as an unchecked checkbox. Users tried to tap/tick it before realizing it isn't interactive; the only real action is the Confirm Delete button. Changed to `"xmark.app.fill"` in `PlanReviewView.PlanItemRow`, which reads unambiguously as "this app is being removed" with nothing to toggle.
- **Clean module audit — several App-Specific Cache, Browser Cache, and System Logs targets pointed at paths that could never exist.** User asked whether the other Clean tasks worked, having only verified Trash. Went through every `CleanScanner` target and checked it against how that app/macOS version actually stores things today (web search per target, since bundle IDs and app cache conventions drift over time and app updates) rather than assuming the original paths were still right:
  - **Dropbox**: bundle ID was truncated to `com.dropbox`; real ID is `com.getdropbox.dropbox`.
  - **Slack** and **Discord**: both Electron apps that don't cache under `~/Library/Caches/<bundle-id>` at all (the code assumed they did, using wrong bundle IDs to boot). Real caches: `~/Library/Application Support/Slack/Cache` and `~/Library/Application Support/discord/Cache`.
  - **Zoom**: real bundle ID is `us.zoom.xos`, not `com.zoom.us` — but confirmed Zoom is one of the few here that *does* cache directly under `~/Library/Caches/<bundle-id>`; added its separate `~/Library/Application Support/zoom.us/data/Cache` too.
  - **Microsoft Teams**: "new Teams" (current) is sandboxed under `com.microsoft.teams2`, not the old `com.microsoft.teams`; its real cache is split across its Container and Group Container, not `~/Library/Caches` at all.
  - **Safari**: sandboxed since Safari 13 (every currently-supported macOS), so its cache lives under its Container, not the old unsandboxed `~/Library/Caches/com.apple.Safari` path.
  - **Edge** and **Brave**: Chromium-based apps that (unlike Safari) don't use their bundle ID as a Caches subfolder name at all — Edge uses `~/Library/Caches/Microsoft Edge`, Brave uses `~/Library/Caches/BraveSoftware/Brave-Browser`. The code had guessed `com.microsoft.edgemac`/`com.brave.Browser`, neither of which exists as a folder name.
  - **System Logs' "temp files" target** was `home.appendingPathComponent("private/tmp")`, resolving to `~/private/tmp` — a path that never exists (a home-relative typo for the real system temp dir). Fixed to `NSTemporaryDirectory()`, the real per-user `$TMPDIR` path.

  None of these were destructive bugs — a target resolving to a nonexistent path just always lands in "Not Found" and reclaims nothing — but it meant a meaningful chunk of App-Specific Cache and Browser Cache was silently dead weight. Verified via a research subagent that no existing test seeds or asserts against any of these specific paths, so the fix carries no test risk. Spotify (`com.spotify.client`) and Firefox (`Library/Caches/Firefox`) were checked and confirmed already correct — left unchanged.
- **Analyser undercounted real disk usage (reported: Home showing only 263GB used).** Root cause: every scan in `DiskScanner` passed `.skipsHiddenFiles` to `FileManager`'s enumerator. macOS flags `~/Library` hidden via `chflags UF_HIDDEN` (not a dot-prefix), so `.skipsHiddenFiles` was silently excluding all of Library — Containers, Application Support, Caches, Mail, Xcode data, often one of the single largest components of a home directory — from both the top-level folder listing and every recursive size total. This matches the earlier observation that Library never appeared at all in the treemap/pie chart. Fixed by removing `.skipsHiddenFiles` from `scan()`, `directorySize()`, `countChildren()`, and `largeFiles()`. To keep the top-level listing free of clutter (dozens of dotfiles like `.zshrc`, `.ssh`, `.npm`), `scan()`/`countChildren()` now apply a manual filter that excludes only dot-prefixed entries — which still excludes `.Trash` and friends from the visible list, but no longer excludes non-dot hidden folders like Library. Size totals (`directorySize`, `largeFiles`) include everything, hidden or not, since a folder's real disk usage doesn't stop at a hidden flag.
