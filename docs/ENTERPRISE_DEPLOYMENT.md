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

The package installs `/Applications/myKikau.app` and no launch daemons. Its one script, `preinstall`, asks a running copy to quit (politely, through Apple Events, so a cleanup in progress finishes or is cancelled first) and waits up to ten seconds, so the version just installed is the one that runs next. The DMG (`make-dmg.sh`) remains the route for individual downloads.

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
| `DisableAutomaticUpdates` | boolean | Switches the updater off: no background checks, no "Check for Updates…" controls, and the update server is never contacted. For fleets that deploy updates themselves. |
| `DisablePrivilegedTools` | boolean | Removes actions that ask for an administrator password (Flush DNS, Renew DHCP), hides the helper's install control, and stops an already-installed helper from being used. |
| `DisableNetworkLookups` | boolean | Hides the two on-request lookups that contact third parties: Applications → Check for Updates (Apple's catalogue and each app's own feed) and Network → Check Public IP (api.ipify.org). |
| `ScheduledScanIntervalHours` | integer | Runs a measuring scan every N hours while the app is running. Never removes anything. The app asks for notification permission at launch so results can be announced; pre-approve it with a Notifications payload (`com.apple.notificationsettings`) for bundle ID `com.profiveck.myKikau`. |
| `LaunchAtLogin` | boolean | Registers (true) or unregisters (false) the app as a login item at every launch and locks the toggle. The usual companion to a scheduled scan. |
| `OrganisationName` | string | Shown in About, Settings and the welcome screen ("Managed by Acme Ltd"). |
| `SupportContact` | string | An https URL, an email address (with or without `mailto:`) or plain text. Shown in About and Settings → Advanced as the first place to go for help. |

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

- **Unified log mirror.** Every entry is also written to the unified log under subsystem `com.profiveck.myKikau`, category `audit`, so log collectors that already gather the unified log (Jamf, Splunk, Kandji, `log collect`) receive the trail without reading users' home folders. Action, outcome, mode and size are public; the file path is marked private and is redacted unless private-data logging is enabled on the Mac.

```bash
log show --last 1d --predicate 'subsystem == "com.profiveck.myKikau" AND category == "audit"'
```

- **CSV safety.** Exported fields that a spreadsheet would read as a formula (`=`, `+`, `-`, `@`) are prefixed with an apostrophe.

Diagnostics (not the audit trail) go to the unified log under the other categories:

```bash
log show --last 1h --predicate 'subsystem == "com.profiveck.myKikau"'
```

## 6. Reporting from a fleet

`mykikau-cli` is read-only and suited to an MDM extension attribute or a scheduled report:

```bash
mykikau-cli scan --json     # reclaimable space by category
mykikau-cli status --json   # CPU, memory, disk, battery health, health score
```

It reads the preference domain, operation log and home folder of **the user it runs as**. An MDM agent runs scripts as root, so run it as the logged-in user to report on their Mac:

```bash
user="$(stat -f%Su /dev/console)"
launchctl asuser "$(id -u "$user")" sudo -u "$user" /Applications/myKikau.app/Contents/Helpers/mykikau-cli scan --json
```

Exclusions and policy then apply exactly as they do in the app. Whatever runs it needs Full Disk Access to see every location.

## 7. The administrator helper

The helper is a launch daemon inside the app bundle (`Contents/MacOS/myKikauHelper`, registered with `SMAppService`). It is dormant until a user installs it from Settings → Advanced and an administrator approves it under System Settings → General → Login Items & Extensions. Every request then needs an administrator password (right `com.profiveck.myKikau.helper.remove`, rule "authenticate as administrator").

It accepts only: application bundles in `/Applications` (one folder deep at most), third-party plists in `/Library/LaunchDaemons` and `/Library/LaunchAgents`, and files in `/Library/PrivilegedHelperTools`. Never Apple's, never security or device-management software, never through a symbolic link, never myKikau itself, and never anything under your `ProtectedPaths` or `ProtectedBundlePrefixes` (it reads those from the managed-preference plists in `/Library/Managed Preferences`, device and user scope). The move itself follows no symbolic links and re-checks the item's identity at the moment it moves, so a folder swapped for a link between the check and the move is refused. It moves items to the calling user's Trash and runs no shell; the one command it spawns is `launchctl bootout` to unload a launch item it is removing. Its own log is `/Library/Logs/myKikau/helper.log`.

To forbid it fleet-wide, set `DisablePrivilegedTools` (hides the install control and stops an installed helper from being used) or build with `MYKIKAU_INCLUDE_HELPER=0`, which leaves it out of the bundle.

## 8. Known limits

- **Privileged helper is opt-in.** By default myKikau runs as the logged-in user and leaves root-owned apps and system-level launch daemons in place. Settings → Advanced can install a launch daemon (approved once by an administrator in System Settings) that removes those after a password prompt; `DisablePrivilegedTools` hides the option. The helper accepts only app bundles in /Applications and third-party launch plists / helper tools in /Library, and only moves them to the user's Trash.
- **Standard (non-admin) users** can clean their own caches, files and user-installed apps, but cannot remove anything in `/Applications` they do not own.
- **Background scans** run only while the app is running (it lives in the menu bar; set `LaunchAtLogin`).
- **Permission prompts that cannot be pre-approved.** The Network screen's Wi-Fi details ask for Location access on request (`network` is behind Advanced tools and can be disabled by policy). Scheduled-scan notifications can be pre-approved with a Notifications payload.
- **English only.**

## 9. Outbound connections

myKikau sends no telemetry and has no crash reporting. The complete list of hosts it can contact:

| Host | When | Policy |
|---|---|---|
| `projectfive.co.ck` (appcast and update downloads) | Daily update check and manual "Check for Updates…" | `DisableAutomaticUpdates` stops both |
| `itunes.apple.com` and each installed app's own `SUFeedURL` host | Applications → Check for Updates (user click) | `DisableNetworkLookups` |
| `api.ipify.org` | Network → Check Public IP (user click) | `DisableNetworkLookups`, or disable `network` |
| `www.projectfive.co.ck`, `github.com` | Links in About, opened in the browser | — |

See [`PRIVACY.md`](../PRIVACY.md) and [`SECURITY.md`](../SECURITY.md).
