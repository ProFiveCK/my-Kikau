# myKikau — Codebase Review (v0.7.0, October 2026)

Scope: `Sources/` (~10,900 lines; the Core module, the scan/delete engines and the main views read in full, the Status monitors, Network and Optimise views sampled), `Tests/`, `scripts/`, packaging config. `swift build` is clean and `swift test` passes (132 tests, 15 suites). Findings come from reading the code; the app UI was not run, so items marked *(unverified at runtime)* are reasoned from the source rather than observed.

## Implementation status (3 October 2026)

The findings below are kept as written on the day of the review. This section records what has since been done on branch `claude/mykikau-codebase-review-56a1cb`.

**Section 1 — safety defects:** all fifteen fixed, each with a regression test (`Tests/myKikauTests/SafetyRegressionTests.swift`, `PathProtectionTests.swift`, `OperationLogTests.swift`). Two Optimise tasks that edited live system data (quarantine history, Spotlight rules) were retired rather than repaired.

**Section 2 — efficiency:** done — no subprocess on the metrics tick (network counters and battery data are read in-process), hostname read once, one metrics collection at a time, cancellable scans with progress, a folder-size cache for Analyse drill-down, in-process plist validation, in-process app metadata, pre-hash for duplicates, bounded large-file search, tail-reading and rotation for the log, deletions off the main thread. Memory pressure now comes from the kernel and battery health is real. Not done: one shared sizing implementation (Clean still reports logical size, Analyse allocated size).

**Section 3 — UI/UX:** done — review sheet with per-item checkboxes, plain-language buttons, progress, results and failure reasons; one Uninstall sheet for the app and its leftovers, with a running-app check; progress and Cancel on scans; results kept when you navigate away; ⌘1–⌘9 and ⌘R; grouped sidebar that reopens on the last screen; Settings with exclusions, log toggle, scan folders, thresholds and background scan; History with Put Back, export and integrity check; VoiceOver labels on the custom controls; shared `Theme`. Not done: native toolbar/`Table`, batch uninstall, localisation, a contrast audit.

**Section 4 — features:** done — itemised Optimise preview, choose-which-copy-to-keep, user-chosen scan folders, external-volume Trash, background scans with notifications, low-disk alert, read-only CLI, Purge behind a developer setting. Not done: Clean rules as external data, app-update check, orphaned-leftover scan, login-items manager, similar photos, history graphs, snapshot comparison, Shortcuts actions.

**Section 5 — enterprise:** done — managed preferences (`ManagedPolicy`), sample MDM profiles, `.pkg` build script, hash-chained and rotated audit log with export, unified logging, diagnostics report, CI workflow, committed `Package.resolved`, inside-out signing. See `docs/ENTERPRISE_DEPLOYMENT.md`. `LICENSE` now carries the full GPL-3.0 text. Not done: privileged helper over XPC, Swift 6 language mode, crash reporting, published privacy and security policies.

**Independent review of the new code:** a second pass over the deletion code found thirteen further issues, all fixed with tests (`ReviewFollowUpTests`): duplicate sets are re-checked on disk before planning; a folder that contains a protected or excluded item can't be removed whole; a second installed copy of an app keeps its data and services; CPU counters no longer trap on wrap; Clean plans are re-checked for in-use items when the review opens; navigation is held while a deletion runs; subprocess timeouts escalate to SIGKILL and are bounded; the log detects entries removed from either end and is flushed at quit; Team-ID matching is confined to Group Containers; Put Back checks the item's identity; Analyse forgets sizes after a removal; exclusions ignore case; Purge finds dot-named folders. Known and accepted: hard-linked files are counted once per path in Analyse.

**Second pass (version 0.8.0):** batch uninstall; a finder for files left by apps removed earlier; a Startup Items screen; CPU and memory trend lines and a compact dashboard; Optimise re-checks each task after a fix; complete data-race checking enabled on every target with no warnings; the code is formatted with SwiftFormat and `scripts/lint.sh` passes (SwiftLint reports no errors; about 50 style warnings remain, mostly lines over 140 characters). The redesigned screens were checked on screen in a development build. **Third pass:** the optional privileged helper (SMAppService daemon over XPC, policy-checked, password per use — exercised end to end on the owner's Mac: approval, password prompt, removal of a root-owned test app); localisation set up with a String Catalog of every extractable string (English shipped); Apps as a native sortable table; an on-request app-update check; similar-photo detection; one shared size measurement (allocated size) used by Clean, Uninstall, Purge and Analyse alike.

**Verified:** `swift build` clean; `swift test` passes (231 tests, 29 suites); the app launches; the CLI runs; the signing script and the package script were exercised with an ad-hoc identity. **Not verified:** an MDM deployment and the installer package signature (no Developer ID Installer certificate is installed on this Mac).

---

## Verdict

The architecture is sound: a four-module package, one deletion funnel, a preview-then-confirm flow, and a thoughtful native metrics layer. What stands between this and an enterprise product is, in order:

1. A handful of Clean and Uninstall targets that break the app's own safety rules (section 1). Fix these before anything else.
2. No managed-deployment story: no privileged helper, no MDM configuration, no tamper-resistant audit log, no CI (section 5).
3. A UI where the review step is all-or-nothing, runs deletions on the main thread, and gives little feedback (section 3).

---

## 1. Safety defects — fix first

| # | Severity | Where | Problem |
|---|---|---|---|
| 1 | Critical | `CleanScanner.swift:71` | "Browser Cache" targets `~/Library/Application Support/Firefox/Profiles` — the whole Firefox profile (bookmarks, saved logins, history), not a cache. The real cache is `~/Library/Caches/Firefox/Profiles/*/cache2`, already covered by line 70. |
| 2 | Critical | `CleanScanner.swift:117` | "System Logs & Temp" targets `NSTemporaryDirectory()` itself. Trashing the per-user temp folder pulls open files out from under every running app, including myKikau and Sparkle. Enumerate its children and skip anything modified recently. |
| 3 | High | `CleanScanner.swift:108` | Targets the whole `~/Library/Logs` folder, which contains myKikau's own `operations.log`. After that clean, `OperationLog.append` fails silently (parent folder gone) until the next launch — the audit trail deletes itself. |
| 4 | High | `CleanScanner.swift:55`, `PathProtection.swift:89` | `isEndpointSecurityBundle` is defined but never called. "User App Cache" plans every child of `~/Library/Caches`, including CrowdStrike/SentinelOne/Jamf caches and all `com.apple.*` caches. The EDR protection the docs describe is not enforced. |
| 5 | High | `LeftoverFinder.swift:84,100,145,147` | Matching is not exact. `hasPrefix(bundleID + ".")` means uninstalling `com.google.Chrome` also sweeps `com.google.Chrome.canary`; ByHost and launch-plist checks use `contains(bundleID)`; `group.` matching has no boundary. A malformed app whose bundle ID is `com` would match every `com.*` preference. Require a full-label match, reject bundle IDs with fewer than three labels, and never plan `com.apple.*` leftovers. |
| 6 | High | `CleanScanner.swift:68,86,103,143` | Non-cache data listed as cache: Safari `CloudTabs.db` (an active database), Xcode `Archives` (shipped builds and dSYMs), `~/.m2/repository` (may hold locally installed artefacts), and the entire Teams Group Container. |
| 7 | High | `MaintenanceRunner.swift:253` | Quarantine cleanup runs `DELETE … ; VACUUM` on a live system database through `sqlite3`. It bypasses `SafeFileDeleter`, is irreversible, and destroys download-origin history that security teams use for incident response. |
| 8 | Medium | `DuplicateFinder.swift:133` | On a read error the hash loop `break`s and returns the partial digest as if complete. Two different files that fail at the same offset would be reported as duplicates. Return `nil` instead. |
| 9 | Medium | `SafeFileDeleter.swift:142-148` | `execute` trusts the plan: it does not re-check `PathProtection`, and `Plan`/`Item` have public initialisers that accept `protected: false`. Permanent deletion is chosen by `category == .trash`, not by the item actually being inside `~/.Trash`. Re-validate at execution time and verify containment. |
| 10 | Medium | `PathProtection.swift:66` | Prefix check on the raw path — no symlink resolution or standardisation, and no guard for `/`, `/Users`, the home folder, `/Applications`, `~/Library/Keychains`, `~/.ssh`, `~/Library/Mail`. SIP covers the system side; the user-data side has no backstop. |
| 11 | Medium | `MaintenanceRunner.swift:555` | A launch agent is "broken" if `ProgramArguments[0]` is not an existing path. launchd resolves bare names through `PATH`, so an agent starting with `sh` or `open`, or one on an unmounted volume, is unloaded and trashed. |
| 12 | Medium | `OptimizeView.swift:197` | Optimise shows only counts ("Would repair 3 preference files") before applying. The user never sees which files will be trashed, which breaks the "user confirms the plan" rule. |
| 13 | Medium | `DuplicateFinder.swift:58` | Hashing reads every candidate, which forces iCloud to download evicted files in Desktop/Documents. Hard links and APFS clones are reported as reclaimable duplicates although removing one frees nothing. |
| 14 | Low | `LoginItemService.swift:43`, `Info.plist` | The System Events script wraps everything in `try`, so it exits 0 even when automation is denied. The app declares no `NSAppleEventsUsageDescription` and no Apple Events entitlement, so under the hardened runtime this step probably never works yet always reports success *(unverified at runtime)*. |
| 15 | Low | `Permissions.swift:26` | Uses `.userDirectory` (which is `/Users`) where the home folder was intended. The class is unused — delete it. |

---

## 2. Efficiency

**Runs every 2 seconds while Status or the HUD is visible**
- `NetworkMonitor.swift:195` spawns `netstat -ib` each tick. `getifaddrs` gives the same byte counters with no process spawn.
- `MetricsCollector.swift:211` calls `ProcessInfo.hostName`, which can block on a reverse DNS lookup. Read it once.
- `MetricsCollector` keeps unsynchronised mutable state (`prevCPUTotal`, the sample boxes) that overlapping `collect()` calls can race on. Make it an actor.

**Scans**
- No scan is cancellable — there is no `Task.isCancelled` check anywhere. Navigating away in Analyse leaves the old walk running; "Scan Everything" cannot be stopped.
- `DiskScanner.scan` re-walks the subtree on every drill-down. Walk once, keep a size tree in memory, and drill-down becomes instant.
- `AppInventory.swift:115` spawns `mdls` once per app, serially, plus a full size walk per app. Use `MDItemCopyAttribute` and a `TaskGroup`.
- `MaintenanceRunner.swift:494` spawns `plutil -lint` once per preference file — hundreds of processes per Optimise scan. `PropertyListSerialization` does this in-process.
- `DuplicateFinder` hashes whole files serially. Add a cheap first/last-64 KB pre-hash and hash in parallel.
- `DiskScanner.largeFiles` collects every file and then sorts; a bounded heap keeps memory flat.

**Other**
- `OperationLog.recent` reads and decodes the whole file. It is called once per task per Optimise scan and on every Status appear. The log never rotates.
- `CleanView.swift:85`, `DuplicatesView.swift:88`, `HUDView.swift:264` call `SafeFileDeleter.execute` synchronously from the button action, so the window freezes while gigabytes move to the Trash. Make `execute` async with progress.
- Three sizing implementations disagree: `SafeFileDeleter.directorySize` (logical size, skips hidden files), `DiskScanner.directorySize` (allocated size, includes hidden), `DuplicateFinder` (logical). Status and Analyse also report different "free" figures. Use one implementation.

**Metric accuracy**
- `MetricsCollector.swift:136`: memory pressure is inferred from free + inactive pages. macOS keeps free memory low by design, so this reads "warn"/"critical" on healthy machines and drags the health score down. Use `kern.memorystatus_vm_pressure_level` and include compressed memory in "used".
- `MetricsCollector.swift:187`: battery cycle count and capacity are hard-coded (0 and 100), so the battery-health part of the score never fires. A full battery on mains shows "Discharging".

---

## 3. UI/UX

**Review sheet (`PlanReviewView`) — the highest-value change**
- Add per-item checkboxes with select-all per group. Today it is all or nothing.
- Replace the "Dry Run" toggle with plain wording. Label the main button with what happens: "Move 42 items to Trash" for recoverable items, and a separate, clearly worded confirmation for Trash contents, which are permanently deleted.
- Add Reveal in Finder, Quick Look and full-path tooltips on rows.
- Show a result: freed space, failures with reasons, and an Undo ("Put Back") for trashed items. Clean currently closes the sheet with no feedback and discards `result.errors`.

**Uninstall**
- `UninstallView.swift:216` sets two `.sheet(item:)` bindings at once (app and leftovers). Merge them into one sheet: app bundle at the top, leftovers grouped by location beneath, each with a checkbox.
- Check `NSRunningApplication` and offer to quit the app first.
- Root-owned apps (Mac App Store, most `.pkg` installs) will fail to trash because there is no privileged path for deletion *(unverified at runtime)*. Detect this up front and explain it rather than failing afterwards.
- Add multi-select for batch uninstall, and filters for "unused 6+ months" and "largest".

**Whole app**
- Scans need determinate progress, the current path, and a Cancel button.
- Use native window chrome: `.toolbar`, `.searchable`, `.navigationTitle`, and a `Table` with sortable columns for apps and files, in place of hand-built headers and search fields.
- Add ⌘1–⌘8 for sidebar navigation, ⌘R to rescan, and remember the last screen.
- Scan results live in view `@State` and are lost on navigation. Move each screen to an observable model.
- Accessibility: there are no accessibility modifiers anywhere in the app. Add VoiceOver labels and values to tiles, charts and icon buttons; do not signal state by colour alone; check contrast on the purple hero card.
- No strings are localised. Move to a String Catalog; it also gives one place to keep NZ/AU spelling consistent.
- Define design tokens (spacing, radius, semantic colours) in the `UI` module. Hard-coded `Color(red:…)` values and 13 separate `.quaternary` card backgrounds will drift.
- Settings has two toggles. Add: exclusions list, operation-log toggle (the rule exists in AGENTS.md but there is no control), scan folders and size thresholds for Files, update channel, notification preferences.
- Bring History back as a proper activity view: date, action, items, space freed, Put Back. It is the trust feature of a cleaner.
- Empty states should run the action on first open or show the last result, rather than a "No Scan Yet" placeholder on every screen.

---

## 4. Feature upgrades and additions

| Area | Upgrade |
|---|---|
| Clean | Rule catalogue as versioned data (JSON) instead of hard-coded paths; skip caches of running apps; age filter; per-app breakdown; external-volume Trash. |
| Apps | App updates check; orphaned-leftover scan for apps already removed; reset an app without uninstalling; login items and background items manager (`SMAppService` status plus launch agents). |
| Files | User-chosen folders; pick which copy to keep; similar-photo detection; old-downloads and old-installer (`.dmg`, `.pkg`) views. |
| Analyse | One-pass size tree; delete and reveal from the map; external and network volumes; snapshot comparison over time ("what grew this week"). |
| Status | History graphs (24 h / 7 d) instead of point values; real battery health; per-process energy impact. |
| Optimise | Itemised preview per task; the sudo-gated tasks through a privileged helper. |
| Automation | Scheduled scans with a notification when reclaimable space crosses a threshold; low-disk alerts; a CLI (`mykikau scan --json`); Shortcuts actions. |
| Purge | Ship it behind a "Developer tools" setting rather than leaving it dormant. |

---

## 5. What makes it enterprise-grade

**Deployment and management**
- Signed and notarised `.pkg` installer alongside the DMG, for Jamf, Intune and Kandji.
- A documented PPPC profile granting Full Disk Access, so IT can pre-approve it and users never see the onboarding prompt.
- Managed preferences: read policy keys from the app's defaults domain so an MDM profile can force or lock settings — disabled features, exclusion paths, operation log always on, update channel or updates off.
- Work correctly for standard (non-admin) users; today several flows assume admin rights.

**Privilege model**
- Replace `osascript … with administrator privileges` (`PrivilegedShell.swift`) with an `SMAppService` daemon reached over XPC. The helper should validate the caller's code signature and expose a small typed API (flush DNS, remove a root-owned app, unload a system launch daemon) instead of accepting shell strings. This also unblocks uninstalling root-owned apps and the seven deferred sudo tasks.

**Audit and compliance**
- Operation log: rotation, a hash chain so tampering is detectable, storage outside any path Clean can touch, and export (CSV/JSON) or forwarding to a SIEM.
- Use `os.Logger` for diagnostics; there is no diagnostic logging at all today.
- A "collect diagnostics" bundle for support.
- Honour EDR and MDM agents by default (finding 4) and let admins extend the protected list by policy.

**Engineering process**
- CI: there is none. Add a macOS runner that builds, tests, and runs SwiftLint/SwiftFormat on every pull request, and a release job that signs and notarises from secrets rather than a developer laptop.
- Commit `Package.resolved` (currently git-ignored). Sparkle floats on `from: 2.9.0`, so release builds are not reproducible and a dependency update is not reviewed.
- `scripts/sign.sh:46` uses `codesign --deep`, which Apple and Sparkle both advise against for signing. Sign nested code inside-out.
- Move to Swift 6 language mode with strict concurrency; it will surface the unsynchronised singletons (`OperationLog.enabled`, `MetricsCollector`, the sample boxes).
- Tests cover scanners and the runner well, but not `PathProtection` edge cases (symlinks, `..`), the leftover-matching boundaries in finding 5, or any view logic. Add those plus a temp-home end-to-end test for each Clean section that asserts exactly which paths are planned.
- Opt-in crash and hang reporting (MetricKit needs no third-party SDK).
- Published privacy policy, security contact, and a release-notes and support-lifecycle page.

**Licensing**
- myKikau is an original, from-scratch implementation released under GPL-3.0. GPL-3.0 allows selling to enterprises but requires offering source to every recipient and rules out closed-source add-ons linked into the app; revisit the licence choice if the commercial plan depends on proprietary modules.
- `LICENSE` contains a header and a link, not the licence text. GPL-3.0 requires the full text to accompany distribution.

---

## Suggested order

1. Findings 1–7 (data-loss and rule violations), with a test per fix.
2. Findings 8–13, async `execute`, and scan cancellation.
3. Review-sheet redesign with per-item selection and results; unified Uninstall sheet.
4. CI, committed lockfile, inside-out signing, full licence text.
5. Privileged helper over XPC.
6. Managed preferences, PPPC profile, `.pkg` installer, audit-log hardening.
7. Feature additions from section 4.
