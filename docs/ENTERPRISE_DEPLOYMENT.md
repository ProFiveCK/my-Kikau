# myKikau — Enterprise Deployment

How to deploy and control myKikau on managed Macs. Sample profiles are in [`docs/enterprise/`](enterprise/).

## 1. Install

Build a signed installer package and push it with your MDM (Jamf, Intune, Kandji, Mosyle):

```bash
./scripts/build-app.sh --release
./scripts/sign.sh "Developer ID Application: Name (TEAMID)"
./scripts/make-pkg.sh "Developer ID Installer: Name (TEAMID)"
xcrun notarytool submit build/myKikau-<version>.pkg --keychain-profile "myKikau-notary" --wait
xcrun stapler staple build/myKikau-<version>.pkg
```

The package installs `/Applications/myKikau.app` and nothing else — no scripts, no launch daemons. The DMG (`make-dmg.sh`) remains the route for individual downloads.

## 2. Pre-approve privacy access

myKikau needs **Full Disk Access** to see other apps' caches and leftovers. Deploy [`myKikau-full-disk-access.mobileconfig`](enterprise/myKikau-full-disk-access.mobileconfig) so users are never asked.

- It must be delivered by MDM; macOS ignores a privacy profile installed by hand.
- Check the code requirement in the profile against your build: `codesign -dr - /Applications/myKikau.app`.
- The profile also approves the one Apple Event the app sends (to System Events, to remove an uninstalled app's "Open at Login" entry).

## 3. Set policy

Policy is read from managed preferences in the domain `com.profiveck.myKikau`. Start from [`myKikau-managed-preferences.mobileconfig`](enterprise/myKikau-managed-preferences.mobileconfig).

A key is honoured only when a profile forces it. A value a user writes with `defaults write` is ignored, so policy cannot be loosened locally. Enforced settings appear disabled in Settings with "Set by your organisation".

| Key | Type | Effect |
|---|---|---|
| `DisabledFeatures` | array of strings | Hides features: `clean`, `uninstall`, `analyze`, `duplicates`, `network`, `optimize`, `startup`, `purge`. They are also skipped by the full scan and the CLI. |
| `ProtectedPaths` | array of strings | Paths (and everything beneath them) that can never be removed. Shown read-only in Settings → Safety. |
| `ProtectedBundlePrefixes` | array of strings | Bundle-ID prefixes treated like security agents: their caches, preferences and containers are never touched and the apps cannot be uninstalled. |
| `ForceOperationLog` | boolean | The operation log cannot be switched off or cleared. |
| `DisableAutomaticUpdates` | boolean | Stops background update checks, for fleets that deploy updates themselves. |
| `DisablePrivilegedTools` | boolean | Removes actions that ask for an administrator password (Flush DNS, Renew DHCP). |
| `ScheduledScanIntervalHours` | integer | Runs a measuring scan every N hours while the app is running. Never removes anything. |

Check what a Mac is actually enforcing:

```bash
/Applications/myKikau.app/Contents/Helpers/mykikau-cli policy --json
```

## 4. What is always protected

Independently of policy, myKikau never removes:

- System locations: `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var/db`, `/Library/Apple`, `/Library/Keychains`, Software Update staging.
- User credentials and data stores: `~/Library/Keychains`, `~/.ssh`, `~/.gnupg`, `~/Library/Mail`, `~/Library/Messages`, iCloud Drive.
- Anything owned by endpoint-security or device-management software (CrowdStrike, SentinelOne, Microsoft Defender, Jamf, Kandji, Intune, Sophos, and others — see `PathProtection.swift`). Add your own with `ProtectedBundlePrefixes`.
- Its own operation log.

Every removal goes to the Trash, except emptying the Trash itself. Nothing is removed without a person reviewing the list first.

## 5. Audit trail

Every action is appended to `~/Library/Logs/myKikau/operations.log` as JSON Lines.

- **Tamper evidence.** Each entry records the SHA-256 of the entry before it. An edited or deleted line breaks the chain.
- **Rotation.** The file rolls at 5 MB; five older files are kept (`operations.1.log` … `operations.5.log`).
- **Collection.** Point your log shipper at that folder, or export on demand:

```bash
mykikau-cli log verify                 # exit 0 = intact, 4 = broken
mykikau-cli log export /path/out.csv --csv
```

Diagnostics (not the audit trail) go to the unified log:

```bash
log show --last 1h --predicate 'subsystem == "com.profiveck.myKikau"'
```

## 6. Reporting from a fleet

`mykikau-cli` is read-only and suited to an MDM extension attribute or a scheduled report:

```bash
mykikau-cli scan --json     # reclaimable space by category
mykikau-cli status --json   # CPU, memory, disk, battery health, health score
```

It reads the same preference domain as the app, so exclusions and policy apply. It needs Full Disk Access for whatever runs it (the MDM agent usually has it) to see every location.

## 7. Known limits

- **Privileged helper is opt-in.** By default myKikau runs as the logged-in user and leaves root-owned apps and system-level launch daemons in place. Settings → Advanced can install a launch daemon (approved once by an administrator in System Settings) that removes those after a password prompt; `DisablePrivilegedTools` hides the option. The helper accepts only app bundles in /Applications and third-party launch plists / helper tools in /Library, and only moves them to the user's Trash.
- **Standard (non-admin) users** can clean their own caches, files and user-installed apps, but cannot remove anything in `/Applications` they do not own.
- **Background scans** run only while the app is running (it lives in the menu bar; enable "Launch at login").
- **English only.**
