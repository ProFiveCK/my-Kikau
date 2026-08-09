# myKikau Agent Guide

This file is the shared source of truth for any AI agent working on this repo. Logic is reimplemented natively in Swift, informed by Mole (Go + Bash, GPL-3.0) at `../Mole`.

## Project

myKikau is a native Swift macOS 14+ system cleanup and optimization app. It performs file cleanup, app uninstall, disk analysis, maintenance, live status monitoring, and dev artifact purge. Safety rules matter more than speed.

## Architecture

SwiftPM package with four modules:
- `App` — `@main` entry, scene composition (window + MenuBarExtra), menu bar HUD
- `Core` — `SafeFileDeleter`, `PathProtection`, `OperationLog`, `Permissions`, `ByteSizeFormatter`
- `Features` — Clean, Uninstall, Analyze, Status, Optimize, Purge modules
- `UI` — shared `PlanReviewView`, reusable components

## Critical Safety Rules

- Route every deletion through `SafeFileDeleter`. It routes to Trash by default, logs to the operation log, honors dry-run, and checks `PathProtection`.
- Never modify protected paths: `/System`, `/Library/Apple`, or `com.apple.*` system bundles (see `PathProtection.swift` for the full list).
- Exact bundle-ID / exact-path evidence for leftovers. Never vendor-prefix, generic-name, or fallback-wildcard matching.
- Preview (dry-run) before every destructive action. The user confirms the plan.
- Reversible (Trash) over permanent delete wherever the surface expects recoverability.
- Never auto-delete Software Update staging trees, active databases, or active dev-tool state.
- Operation log appends to `~/Library/Logs/myKikau/operations.log` as JSONL. Respect the user toggle.

## Reference Files (Mole)

When porting logic, consult:
- `../Mole/lib/core/app_protection_data.sh` — protected bundle IDs
- `../Mole/lib/core/app_protection.sh` — protection matching logic
- `../Mole/lib/core/file_ops.sh` — `mole_delete` deletion funnel
- `../Mole/lib/clean/*.sh` — per-category cleanup target paths
- `../Mole/lib/uninstall/*.sh` — app inventory + leftover teardown
- `../Mole/lib/optimize/catalog.sh` — maintenance task catalog
- `../Mole/cmd/status/metrics.go` + `metrics_health.go` — metrics + health score
- `../Mole/lib/clean/project.sh` — purge targets (node_modules, target, build, dist, .build, venv)
- `../Mole/AGENTS.md` — safety rules and product direction

## Build

```bash
swift build
swift test
```

## Git

- Do not add AI attribution trailers to commits.
- Do not commit changes unless the user explicitly asks.