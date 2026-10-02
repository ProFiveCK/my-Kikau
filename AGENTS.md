# myKikau Agent Guide

This file is the shared source of truth for any AI agent working on this repo.

## Project

myKikau is a native Swift macOS 14+ system cleanup and optimisation app. It performs file cleanup, app uninstall, disk analysis, maintenance, and live status monitoring (a dev artifact purge scanner exists in the codebase but is held back from the current release — not shown in the UI). Safety rules matter more than speed.

## Architecture

SwiftPM package with five modules:
- `App` — `@main` entry, scene composition (window + MenuBarExtra), menu bar HUD, per-screen models (`ScreenModels.swift`)
- `Core` — `SafeFileDeleter`, `PathProtection`, `OperationLog`, `ProcessRunner`, `ManagedPolicy`, `ExclusionStore`, `Log`, `ByteSizeFormatter`
- `Features` — Clean, Uninstall, Analyze, Duplicates, Status, Optimize, Purge, Network, Diagnostics
- `UI` — shared `PlanReviewView`, `Theme`, reusable components
- `CLI` — `mykikau-cli`, read-only reporting (never deletes)

Scan results live in `ScanEverythingCoordinator`; screens read and update them there rather than holding their own copies.

## Critical Safety Rules

- Route every deletion through `SafeFileDeleter`. It routes to Trash by default, logs to the operation log, honors dry-run, and checks `PathProtection` — at preview and again at execution. Never trust a plan.
- Permanent removal exists only for items physically inside a Trash folder. Nothing else may bypass the Trash.
- Never modify protected paths: `/System`, `/Library/Apple`, `com.apple.*` system bundles, user credential/data stores, security and device-management software, the app's own log, and user/administrator exclusions (see `PathProtection.swift` for the full list).
- A Clean target must be data an app rebuilds by itself. Never a profile, database, archive, or anything a user created. Never target a shared container (`~/Library/Caches`, `~/Library/Logs`, the temp folder) itself — target its children.
- Exact bundle-ID / exact-path evidence for leftovers. Never vendor-prefix, generic-name, substring, or fallback-wildcard matching. `com.vendor.app` must not match `com.vendor.app.other`.
- Never edit a live system database or system-owned preference in place.
- Preview before every destructive action: the user sees the exact items and confirms. A count is not a preview.
- Spawn subprocesses only through `ProcessRunner`, and never from code that runs on every metrics tick.
- Scans must be cancellable and must not run on the main thread.
- Any new safety rule gets a regression test in `Tests/myKikauTests/SafetyRegressionTests.swift`.
- Reversible (Trash) over permanent delete wherever the surface expects recoverability.
- Never auto-delete Software Update staging trees, active databases, or active dev-tool state.
- Operation log appends to `~/Library/Logs/myKikau/operations.log` as JSONL. Respect the user toggle.

## Build

```bash
swift build
swift test
```

## Git

- Do not add AI attribution trailers to commits.
- Do not commit changes unless the user explicitly asks.