# myKikau — Codebase Review & Modernization Plan

*Reviewed against CleanMyMac (MacPaw), 2026 lineup. ~6,800 lines across Sources/ and Tests/.*

## Bottom line

The engineering underneath myKikau is genuinely strong — stronger, in places, than what "underwhelming" suggests. The safety layer (protected paths, EDR exclusions, dry-run + plan review before every delete), the 22-task maintenance catalog, the leftover-aware uninstaller, and the from-scratch native metrics collector (CPU/memory/disk/network/GPU/thermal/battery via Mach, IOKit, and sysctl) are all real, working implementations — not stubs. What's missing isn't capability, it's presentation: every screen is a plain `List` with text rows on a `.quaternary` background. CleanMyMac's edge isn't that it does more under the hood — by your numbers it may do less in places — it's that everything is illustrated, color-coded, and organized around one-click entry points. That's a fixable, mostly-visual gap.

One thing surfaced during the review needed fixing regardless of the modernization question: **the Cancel button in the delete-confirmation sheet was wired to actually execute the deletion.** Details below — already patched.

---

## 1. Critical fix applied

`PlanReviewView` (used by Clean, Uninstall, and Purge before anything is trashed) took a single `onExecute(Bool)` callback where `true` meant "dry run" and `false` meant "go ahead and delete." The Cancel button called `onExecute(false)` — the same signal as confirming a real deletion. Every caller (`CleanView`, `UninstallView` ×2, `PurgeView`) then ran `SafeFileDeleter.execute(..., dryRun: false, ...)`, so clicking **Cancel** on any delete confirmation actually trashed the selected items instead of dismissing the sheet.

Fixed by giving `PlanReviewView` a dedicated `onCancel` closure, separate from `onExecute`, and wiring Cancel to it in all four sheet call sites. Files touched: `Sources/UI/PlanReviewView.swift`, `Sources/App/CleanView.swift`, `Sources/App/UninstallView.swift`, `Sources/App/PurgeView.swift`. Items were going to the Finder Trash (recoverable), not permanently deleted, but this is exactly the kind of bug that erodes trust fast in a tool whose entire pitch is "safe to delete things for you."

Also implemented this session, since you specifically asked for it:

- **Status is now the launch screen.** `ContentView`'s default selection changed from `.clean` to `.status`, and it's now first in the sidebar.
- **Status is now a dashboard hub.** Added a "Quick Actions" grid of six tappable cards (Clean, Uninstall, Analyze, Optimize, Purge, History) directly under the health banner — clicking one navigates the sidebar, so Status is genuinely the front door into everything else, not just a read-only metrics page.
- **Real app icons in the Uninstaller.** Swapped the generic `app.dashed` SF Symbol for `NSWorkspace.shared.icon(forFile:)`, so the list actually looks like the apps it's listing. Small change, disproportionate visual payoff.

---

## 2. What's already competitive (don't rebuild these)

- **Safety model.** `PathProtection` blocks system paths and ~90 critical bundle IDs, *and* explicitly excludes EDR/MDM agent caches (CrowdStrike, SentinelOne, ESET, Jamf) from tampering — a level of care aimed at IT-managed machines that CleanMyMac doesn't advertise. Every deletion routes through one funnel (`SafeFileDeleter`) with a mandatory preview → plan → confirm flow and an append-only JSONL operation log. This is a stronger trust story than CleanMyMac's opaque "Safety Database" — you just aren't telling anyone about it yet.
- **Maintenance catalog.** 22 real macOS maintenance tasks (Spotlight rebuild with smart detection, LaunchServices repair, quarantine DB cleanup, orphaned LaunchAgents, periodic scripts, permission repair, etc.), each with sudo/auto-safety flags. This maps closely to CleanMyMac's Performance module and in places goes deeper.
- **Project Purge.** Scanning for `node_modules`, build/, target/, and other dev-tool artifacts is something CleanMyMac does *not* do well — it's generic "large files," not project-aware. For a developer audience this is a genuine differentiator worth marketing, not just matching CleanMyMac feature-for-feature.
- **Uninstaller depth.** Leftover finder + LaunchAgent unload + login-item teardown + LaunchServices re-registration is real app-teardown logic, on par with CleanMyMac's Applications module.
- **System status depth.** CPU, memory, disk, network throughput, GPU, thermal/fan, battery, disk I/O — collected natively, no shell-outs. This is closer to iStat Menus territory than CleanMyMac's simpler overview.

---

## 3. Gap analysis vs. CleanMyMac (2026)

| CleanMyMac has | myKikau today | Verdict |
|---|---|---|
| One-click "Smart Care" scanning all modules at once | Each module (Clean/Uninstall/Analyze/Purge) is scanned separately, by hand | **Gap** — biggest single UX difference |
| Space Lens: interactive bubble/treemap storage map | `AnalyzeView` is a flat, unsorted `List` | **Gap** — high visual impact if added |
| Protection module: malware scan (Moonlock engine), mic/camera access audit | Nothing | **Gap** — biggest feature gap, but see §5 on scope |
| My Clutter: duplicate & large/old file finder across the whole disk | Not present (Analyze only walks folders you navigate into) | **Gap** |
| Menu bar widget with *actionable* buttons (free RAM, empty trash) | `HUDView` is read-only metrics, no actions | **Gap**, small effort |
| App icons, colored module branding throughout | Generic SF Symbols, monochrome `.quaternary` cards everywhere | **Gap** — mostly styling, now partially fixed on Status/Uninstall |
| Contextual, per-module permission prompts on first use | `Permissions.swift` (bookmark storage) exists but nothing in the UI ever calls it | **Gap** — dead code, no onboarding |
| Cloud Cleanup (iCloud/Google Drive/OneDrive) | Not present | Gap, but niche — low priority |
| My Tools: pin frequent tasks into a custom workflow | Not present | Nice-to-have, not urgent |

---

## 4. Why it "feels" underwhelming — the visual diagnosis

Every screen follows the same pattern: title bar → `Button` → `List`/`ScrollView` of plain rows on `.quaternary` backgrounds. There's no color language distinguishing modules (Quick Actions now gives Status one, but Clean/Uninstall/Analyze/Optimize/Purge still don't carry it into their own screens), no charts anywhere (not even a sparkline on CPU/memory history, despite `MetricsCollector` already sampling every 2 seconds), no treemap/bubble view for storage, and selection states are sometimes invisible (Purge lets you tap artifacts to select them but shows no checkmark or highlight — you can't tell what's selected without scrolling to the count at the bottom). None of this is an engineering problem; it's an unallocated design pass. The fastest way to close the visible gap with CleanMyMac is a UI pass, not new subsystems.

---

## 5. A structural point worth deciding early: App Store vs. direct distribution

This connects back to the earlier question about Xcode/App Store prep. CleanMyMac itself is **not primarily an App Store app** for a specific reason: the Mac App Store version is explicitly crippled relative to the direct-download version — no Speed scanner (replaced with a weaker Large & Old Files scanner), no Xcode Simulator/System Log/Language File cleanup, no Wi-Fi network or Safari cookie management, login items/launch agents visible but not toggleable, can't remove App Store app binaries, no real-time malware monitoring. That's not MacPaw being lazy — it's what App Sandbox actually allows. A tool whose entire purpose is reaching into other apps' caches, LaunchAgents, and Trash fundamentally conflicts with the sandbox model App Store submission requires.

myKikau's core value (leftover-aware uninstall, LaunchAgent teardown, cross-app cache cleanup, project artifact purging) is exactly the category of functionality that doesn't survive sandboxing intact. If the goal is genuinely to *replace* CleanMyMac, direct distribution — notarized, signed, downloaded from your own site (same path CleanMyMac, Onyx, and AppCleaner all take) — is almost certainly the right target, with Mac App Store treated as, at best, a limited-feature companion listing later. Worth deciding now, since it changes what "prepare for release" means (notarization + Sparkle-style update channel, vs. App Store Connect entitlements wrangling).

---

## 6. Recommended priority order

**Already done this session**
1. Fixed the Cancel-deletes-your-files bug.
2. Status is now the landing screen and doubles as a dashboard with clickable navigation into every feature.
3. Real app icons in the Uninstaller.

**Quick wins (visual, low effort, high perceived-quality payoff)**
4. Give each module screen its own accent color, carried from the new Quick Actions tint into that module's own header/buttons, so the app reads as designed rather than default-SwiftUI.
5. Add a visible selection state to Purge's artifact list (checkmark/highlight on tap) — right now selection is invisible.
6. Add 1–2 actionable buttons to the menu bar HUD (Empty Trash, Free Up Memory) instead of read-only metrics.
7. Remove the dead `Permissions.swift` bookmark system or wire it into a first-launch onboarding screen that explains why Full Disk Access is needed — right now it's unused code and the app never asks for the access it needs, so features will silently under-report or fail the first time a user runs them.
8. Sparkline the last ~30 samples of CPU/memory on the Status cards — the data's already being collected every 2 seconds and thrown away.

**Medium effort, real feature gaps**
9. A single "Scan Everything" action on the dashboard that kicks off Clean + Analyze + Purge scans together and surfaces one combined "X GB reclaimable" number — this is the single biggest UX gap vs. CleanMyMac's Smart Care.
10. A duplicate/large-file finder across the whole home directory (not just folder-by-folder browsing) — closest equivalent to My Clutter.
11. Consolidate `MetricsCollector` polling: Status and the menu bar HUD each run their own independent 2-second timer and `collect()` call right now — wasteful, and will drift out of sync. Centralize into one observable service both views subscribe to.

**Bigger bets, decide scope deliberately**
12. A visual storage map (treemap or bubble chart) for Analyze — this is the single highest-visual-impact feature CleanMyMac has that you don't, but it's a real engineering project, not a styling pass.
13. Malware/protection scanning — biggest feature gap, but also the most scope, trust, and (if you ever do want App Store presence) entitlement risk. Worth scoping separately rather than folding into a UI pass.

---

## 7. Bugs / rough edges noticed in passing

- `CleanView`'s original `if !dryRun || dryRun { ... }` was a tautology (always true) — harmless once the Cancel fix landed, and already cleaned up as part of that fix.
- `AppInventory` never fetches `NSWorkspace` icons for its own model — the fix in `UninstallView` fetches on every row render rather than caching; fine at current list sizes (tens of apps) but worth caching if the list grows or scroll performance becomes visible.
- `AnalyzeView`'s file list isn't sorted by size — worth defaulting to largest-first, since that's the only reason someone opens a disk analyzer.
