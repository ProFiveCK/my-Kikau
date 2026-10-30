# Security

## Reporting a vulnerability

Email **security@projectfive.co.ck** with the version (About → Version), what you found and how to reproduce it. Please don't open a public issue for a vulnerability until a fix has shipped. You will get an acknowledgement within five working days and a fix or a plan within thirty.

## What the app is designed to guarantee

- **One deletion funnel.** Every removal goes through `SafeFileDeleter`, which moves items to the Trash, writes the operation log, honours dry-run and checks protection rules at preview time and again at the moment of deletion.
- **Nothing is removed without a person reviewing the exact list.** Permanent removal exists only for items already in a Trash folder, after a second confirmation.
- **Never touched:** `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var/db`, `/Library/Apple`, keychains, `~/.ssh`, `~/.gnupg`, Mail, Messages, iCloud Drive, endpoint-security and device-management software, the app's own log, and anything an administrator or user excludes. Comparisons ignore letter case, resolve symbolic links and treat a `..` segment as what it points to.
- **Exact evidence for leftovers.** An app's files are matched by its exact bundle identifier or exact path, never by vendor prefix, substring or wildcard.
- **Tamper-evident audit log.** Each JSON Lines entry carries the SHA-256 of the entry before it; `mykikau-cli log verify` reports a broken chain. CSV exports neutralise spreadsheet formulas.
- **No elevation by default.** The app runs as the logged-in user and spawns programs only through one bounded runner, never on a timer. The optional administrator helper is a launch daemon that an administrator must approve, that checks the caller's code signature, requires an administrator's authorisation per request, judges every path from the file system itself (three allowed locations, never Apple's or security software, never through a symbolic link, never anything an organisation protects), and moves items without following links after re-checking their identity. It runs no shell.
- **Hardened runtime, notarised, no App Sandbox** (direct distribution needs Full Disk Access, which the sandbox prevents). The only entitlement is Apple Events, for removing an uninstalled app's login item.
- **Policy cannot be loosened locally.** Managed preferences count only when a profile forces them.

Every safety rule has a regression test in `Tests/myKikauTests/SafetyRegressionTests.swift`.

## Supported versions

The current release and the one before it receive security fixes. Enterprise customers deploying through MDM can switch off the built-in updater (`DisableAutomaticUpdates`) and ship releases themselves; see `docs/ENTERPRISE_DEPLOYMENT.md`.

## Build integrity

Dependencies are pinned in `Package.resolved` and CI fails if resolving would change it. The only dependency is Sparkle (update framework); updates are verified with an EdDSA key embedded in the app.
