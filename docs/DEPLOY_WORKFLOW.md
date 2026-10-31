# Deploy Workflow — shipping a new myKikau version

A step-by-step runbook for every release after 0.2.0. Written so an AI agent
with file + shell access to this repo can execute the automatable parts
directly, and so a human knows exactly what's left for them at each point
where the agent can't reach (website CMS, GitHub web UI, unless those get
connected via MCP later).

The current pipeline is fully scriptable on the release Mac when the existing
keychain and Hostinger credentials are available. In that environment, an agent
can execute signing and deployment directly when the user authorizes a release.
projectfive.co.ck is a static site on Hostinger (behind Cloudflare), built from
`~/MyProjects/projectfive/website-renew/site`; the myKikau section of `/apps/`
takes its version and DMG size from that site's `src/mykikau.json`.

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

It refuses to run unless HEAD is on `origin/main`. It cleans and regenerates
the canonical `build/release/` folder, copies only this version's DMG into it
(the feed lists one version; older local DMGs are often rebuilds that don't
match the website's files), writes `build/release/appcast.xml`, creates
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
scripts/prepare-deploy.sh "build/myKikau-${VERSION}.dmg" https://projectfive.co.ck/downloads/
```

## 5. Deploy to the website **[AGENT — Hostinger API]**

One script stages the release into the static site, rebuilds it and uploads
the changed files through the Hostinger API — no File Manager or FTP.

**Prerequisites:**
- `~/.hermes/secrets/hostinger.env` with `HOSTINGER_API_TOKEN` (hPanel → API).
- Optional: `~/.hermes/secrets/cloudflare.env` with `CLOUDFLARE_API_TOKEN`
  (Zone → Cache Purge permission) and `CLOUDFLARE_ZONE`. Cloudflare doesn't
  cache the pages or the feed today, so a failed purge only warns.
- Node.js, for the site's `npm run build` and `npm run check`.

```bash
# Stage, build and check the site; upload nothing:
python3 scripts/deploy-website.py --version 0.10.3 --dry-run

# Full deploy:
python3 scripts/deploy-website.py --version 0.10.3

# Upload particular built files only (e.g. a site-wide .htaccess change):
python3 scripts/deploy-website.py --only .htaccess
```

The script:
1. Checks `website-upload/<version>/` has the DMG and an appcast that lists it.
2. Copies both into the site's `public/downloads/`, writes the version and DMG
   size to `src/mykikau.json`, then runs the site's build and check.
3. Saves the current remote text files to
   `~/.hermes/cache/projectfive_mykikau_backups/<timestamp>/`.
4. Uploads, in this order, through Hostinger's upload URL (TUS, overwriting):
   `downloads/myKikau-<version>.dmg`, `apps/index.html`, `.htaccess`, and
   `downloads/appcast.xml` last, so the feed never points at a missing DMG.
5. Purges those URLs from Cloudflare.
6. Verifies the public DMG checksum, both feed URLs and the `/apps/` link.

**Feed URLs:** builds from 0.10.3 read `https://projectfive.co.ck/downloads/appcast.xml`.
Builds up to 0.10.2 read `https://www.projectfive.co.ck/apps/appcast.xml`; the
site's `.htaccess` (generated by `scripts/build.mjs`) redirects `www` to the
apex and serves `/apps/appcast.xml` from `/downloads/appcast.xml`. Keep that
rule as long as older builds are in use.

## 6. Update the website copy **[AGENT]**

Release notes go in a `### Version <version>` section of `docs/WEBSITE_COPY.md`
(prepare-deploy fails without one). Any other change to the `/apps/` wording
is made in the site's `src/pages.mjs`.

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

- Fetch `https://projectfive.co.ck/apps/` — confirm the version
  number, download link, and release notes match what was just shipped
- Fetch `https://projectfive.co.ck/downloads/appcast.xml` — confirm it
  returns `200` with `Content-Type: application/xml` (a fetch tool that
  can't render XML as text is fine — the status + content-type alone confirm
  it's live, not a 404)
- Fetch `https://github.com/ProFiveCK/my-Kikau/releases` — confirm the new
  tag appears and isn't showing "no releases"

Report back a short pass/fail list rather than assuming success.

---

## Quick reference — the whole sequence

Agents: steps 4 onward are public (main, GitHub release, website). Do them
only after the owner explicitly says to release, in this conversation. That
includes a website-only upload with `deploy-website.py --only`.

```
1. On a branch: code + swift build && swift test && scripts/lint.sh
2. In the same branch: scripts/bump-version.sh patch|minor, and a
   "### Version X.Y.Z" section in docs/WEBSITE_COPY.md
3. Open the PR; wait for CI to pass
4. Merge the PR (merge commit), then in the release checkout:
     git fetch origin && git merge --ff-only origin/main
5. scripts/release.sh            # build, sign, DMG, notarise (5–15 min)
6. scripts/prepare-deploy.sh     # refuses unless HEAD is on origin/main
7. python3 scripts/deploy-website.py --version X.Y.Z --dry-run, then without --dry-run
8. Verify: feed and /apps/ show X.Y.Z, public DMG checksum matches build/,
   GitHub release vX.Y.Z exists with the DMG attached
```

Release from the checkout that holds earlier `build/myKikau-*.dmg` files only
if you like; nothing depends on them any more.

## Troubleshooting

- **Notarisation sits on "Conducting pre-submission checks…"** — macOS had
  attached the new DMG in the background, which locks it. `notarize.sh` now
  detaches it before signing, submitting and stapling. If it still hangs,
  check `hdiutil info` for the DMG path and `hdiutil detach /dev/diskN`, then
  re-run only `scripts/notarize.sh build/myKikau-X.Y.Z.dmg` (the build and
  DMG are fine). `--timeout 1h` stops a stuck wait from running forever.
- **notarytool: "must be a zip archive, flat installer package, or UDIF disk
  image"** — it was interrupted while reading a locked DMG. Re-run
  `notarize.sh` on the same file.
- **prepare-deploy: "HEAD is not on origin/main"** — the PR isn't merged, or
  this checkout hasn't been fast-forwarded. Never release a feature branch.
- **Cloudflare purge: HTTP 401** — the token in `~/.hermes/secrets/cloudflare.env`
  has expired. Only a warning: Cloudflare doesn't cache the feed or pages.
  The owner renews it in the Cloudflare dashboard.

## Scriptability status

The full pipeline is scriptable from the local Mac:

```bash
scripts/release.sh          # build + sign + package + notarize
scripts/prepare-deploy.sh   # appcast + release notes + website-upload folder + GitHub release
scripts/deploy-website.py   # Hostinger API: stage + build site, upload DMG, page, feed; verify
```
