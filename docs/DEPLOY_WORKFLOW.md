# Deploy Workflow — shipping a new myKikau version

A step-by-step runbook for every release after 0.2.0. Written so an AI agent
with file + shell access to this repo can execute the automatable parts
directly, and so a human knows exactly what's left for them at each point
where the agent can't reach (website CMS, GitHub web UI, unless those get
connected via MCP later).

Each step is tagged:
- **[AGENT]** — doable directly with file/bash access to this repo. No login,
  no browser, no credentials beyond what's already in the local keychain.
- **[HUMAN]** — needs a login, a browser, or a credential the agent doesn't
  have. The agent should stop and hand this back rather than guess.

---

## 0. Prerequisites (one-time, already done as of 0.2.0)

These don't repeat per release — listed only so an agent can sanity-check
they're still true before starting:

- `MYKIKAU_SIGN_IDENTITY` exported in the shell profile (`~/.zshrc`), or the
  identity string ready to pass to `scripts/release.sh` directly.
- `xcrun notarytool store-credentials "myKikau-notary" ...` already run once
  (credentials live in the login keychain).
- Sparkle EdDSA keypair generated; the **public** half is in
  `Sources/App/Info.plist`'s `SUPublicEDKey`. Private half lives in the login
  keychain — never touches this repo.

If any of these aren't true, stop and get them sorted first — every step
below assumes they're already in place.

---

## 1. Make the code changes **[AGENT]**

Normal development. Before moving on, sanity-check:

```bash
swift build              # confirms it compiles
swift test                # runs the test suite
```

There's no Swift toolchain in a sandboxed Linux agent environment — if
you're an agent working from one, you can't run this yourself. Say so
explicitly and ask the user to run it, or to report back the exact error if
`scripts/build-app.sh --release` fails later in this workflow. Don't assume
a build succeeds just because the edits looked reasonable.

## 2. Decide and apply the version bump **[AGENT + HUMAN judgment call]**

Bump both keys in `Sources/App/Info.plist`:

- `CFBundleShortVersionString` — user-facing semver (`0.2.0` → `0.3.0` for a
  feature release, `0.2.1` for a fix-only release)
- `CFBundleVersion` — a strictly increasing build number, bump on every
  build even between semver releases

Use the helper script so the release version is controlled and repeatable:

```bash
scripts/bump-version.sh patch       # fix-only release, e.g. 0.2.1 -> 0.2.2
scripts/bump-version.sh minor       # feature release, e.g. 0.2.1 -> 0.3.0
scripts/bump-version.sh major       # breaking/major release, e.g. 0.2.1 -> 1.0.0
scripts/bump-version.sh 0.3.0       # explicit version, build auto-increments
scripts/bump-version.sh 0.3.0 7     # explicit version and build number
```

The script updates both `CFBundleShortVersionString` and `CFBundleVersion`.
Which semver bump to use is still a product judgment call; ask the user if
it's not obvious from the changes made.

## 3. Build, sign, package, notarize **[AGENT triggers, HUMAN's Mac executes]**

This *must* run on an actual Mac with the Developer ID certificate in its
keychain — an agent in a sandboxed environment cannot do this step itself,
only tell the user the exact command:

```bash
scripts/release.sh
```

This chains `build-app.sh --release` → `sign.sh` → `make-dmg.sh` →
`notarize.sh` and fails fast if the signing identity isn't available. It
prints the final DMG path when done, e.g. `build/myKikau-0.3.0.dmg`.

Notarization typically takes a few minutes, occasionally up to an hour. The
user should report back the final DMG path (or any error output) before
continuing.

## 4. Generate the appcast **[AGENT triggers, HUMAN's Mac executes]**

Use the deploy-prep script rather than running `update-appcast.sh` directly
against `build/`:

```bash
scripts/prepare-deploy.sh
```

This cleans and regenerates the canonical `build/release/` folder, copies the
versioned DMGs into it, writes `build/release/appcast.xml`, creates
`build/release/release-notes-${VERSION}.md`, creates a versioned
`website-upload/${VERSION}/` handoff folder, pushes the current branch to
`origin`, and creates/updates the GitHub Release when `gh` is installed and
authenticated.

Do not run `scripts/update-appcast.sh build` directly. That creates a duplicate
`build/appcast.xml` and root-level delta files. `build/release/appcast.xml` is
the file to upload.

If the DMG is going somewhere other than the default downloads URL, pass the
download URL prefix explicitly:

```bash
scripts/prepare-deploy.sh "build/myKikau-${VERSION}.dmg" https://www.projectfive.co.ck/downloads/
```

## 5. Upload the DMG and appcast.xml **[AGENT — Plesk API]**

The DMG, appcast.xml, and WordPress page update are all handled by a single
script that talks to the Plesk REST API directly — no FTP, no WordPress admin
panel, no manual browser work.

**Prerequisite:** Plesk credentials at `~/.hermes/secrets/plesk-hostme.env`
(copied from nrbot001:/home/ubuntu/.hermes/secrets/plesk-hostme.env). This file
contains the Plesk API URL, username, password, and WordPress admin creds.

```bash
# Dry run — validate artifacts and check what would be deployed:
python3 scripts/deploy-website.py --dry-run

# Full deploy — upload DMG, appcast, update WordPress page, verify:
python3 scripts/deploy-website.py

# Deploy a specific version:
python3 scripts/deploy-website.py --version 0.4.3

# Skip individual steps if already done:
python3 scripts/deploy-website.py --skip-dmg --skip-appcast  # just update WP page
python3 scripts/deploy-website.py --skip-page               # just upload files
```

The script:
1. Validates all artifacts in `website-upload/<version>/` exist and contain
   the right version markers
2. Backs up the current remote appcast + WordPress page to
   `~/.hermes/cache/projectfive_mykikau_backups/<timestamp>/`
3. Uploads the DMG to `/downloads/myKikau-<version>.dmg` via Plesk fs API
4. Uploads `appcast.xml` to `/downloads/appcast.xml` via Plesk fs API
5. Updates WordPress page (ID 61) via a temporary self-deleting PHP script
   that directly updates `wp_posts.post_content` (the script is deleted
   immediately after use)
6. Verifies all public URLs serve the correct content (DMG sha256, appcast
   version markers, page download link)
7. Reports a pass/fail summary

**File locations on the server:**
- DMG → `/downloads/myKikau-<version>.dmg`
- appcast.xml → `/downloads/appcast.xml`
- WordPress page → page ID 61 at `/apps/mykikau/`

**Note:** The appcast.xml is uploaded to `/downloads/appcast.xml`, which is
where `SUFeedURL` in `Info.plist` points. Make sure the SUFeedURL in
Info.plist matches this location.

## 6. Update the website content **[AGENT]**

`docs/WEBSITE_COPY.md` is the source of truth for the download page's copy.
Before deploying, update that file (and the mirrored
`docs/download-page-mockup.html` / `wordpress-page.html`) to describe what
actually changed — version number, download size, and a fresh Release Notes
section (New / Improved / Fixed). Then run `scripts/prepare-deploy.sh` to
regenerate the `website-upload/<version>/wordpress-page.html` from
`docs/download-page-mockup.html`, and finally `scripts/deploy-website.py` to
push it live.

The feature-highlight cards in the HTML must match `WEBSITE_COPY.md`'s
feature bullet list — this is exactly what drifted and caused the stale
"Purge" mismatch during 0.2.0. Keep the two in sync every time.

The WordPress page update is handled automatically by `deploy-website.py`
(step 5) — no manual WordPress admin work needed.

## 7. Publish a GitHub Release **[HUMAN — GitHub web UI, unless `gh` CLI + auth exists]**

This is scripted by `scripts/prepare-deploy.sh` when `gh` is installed and
authenticated. It creates or updates tag/release `v${VERSION}`, attaches the
DMG, and uses release notes extracted from `docs/WEBSITE_COPY.md`.

To intentionally skip the GitHub release during a dry run:

```bash
MYKIKAU_SKIP_GITHUB_RELEASE=1 scripts/prepare-deploy.sh
```

To create/update the GitHub Release without pushing first:

```bash
MYKIKAU_SKIP_GIT_PUSH=1 scripts/prepare-deploy.sh
```

## 8. Final verification **[AGENT, via web_fetch]**

Once steps 5–7 are done, an agent can confirm everything landed correctly
without asking the human to check by hand:

- Fetch `https://www.projectfive.co.ck/apps/mykikau/` — confirm the version
  number, download link, and release notes match what was just shipped
- Fetch `https://www.projectfive.co.ck/apps/appcast.xml` — confirm it
  returns `200` with `Content-Type: application/xml` (a fetch tool that
  can't render XML as text is fine — the status + content-type alone confirm
  it's live, not a 404)
- Fetch `https://github.com/ProFiveCK/my-Kikau/releases` — confirm the new
  tag appears and isn't showing "no releases"

Report back a short pass/fail list rather than assuming success.

---

## Quick reference — the whole sequence

```
1. Make changes, swift build && swift test
2. Bump Info.plist version
3. scripts/release.sh
4. scripts/prepare-deploy.sh
5. python3 scripts/deploy-website.py                              [agent — Plesk API]
6. WordPress page updated automatically by deploy-website.py      [agent]
7. GitHub release is created/updated by prepare-deploy.sh         [agent]
8. Verify all three URLs reflect the new release                  [agent]
```

## Scriptability status

The full pipeline is now scriptable from the local Mac:

```bash
scripts/release.sh          # build + sign + package + notarize
scripts/prepare-deploy.sh    # appcast + release notes + website-upload folder + GitHub release
scripts/deploy-website.py   # Plesk API: upload DMG + appcast + update WordPress page + verify
```

Steps 5-6 (DMG upload, appcast upload, WordPress page update) are now fully
automated via `scripts/deploy-website.py`, which uses the Plesk REST API and a
temporary self-deleting PHP script for the WordPress DB update. No manual FTP,
WordPress admin, or browser work needed.

**Credential file:** `~/.hermes/secrets/plesk-hostme.env` (copied from
nrbot001:/home/ubuntu/.hermes/secrets/plesk-hostme.env). Contains Plesk API
URL, username, password, and WordPress admin creds.

**Backups:** Before each deploy, the script backs up the current remote
appcast.xml and WordPress page HTML to
`~/.hermes/cache/projectfive_mykikau_backups/<timestamp>/`.

**Verification:** After upload, the script fetches all three public URLs
(DMG, appcast, WordPress page) and verifies content matches — DMG sha256,
appcast version markers, and page download link. Reports pass/fail summary.
