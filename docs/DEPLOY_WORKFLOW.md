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

## 2. Decide the version bump **[AGENT + HUMAN judgment call]**

Bump both keys in `Sources/App/Info.plist`:

- `CFBundleShortVersionString` — user-facing semver (`0.2.0` → `0.3.0` for a
  feature release, `0.2.1` for a fix-only release)
- `CFBundleVersion` — a strictly increasing build number, bump on every
  build even between semver releases

The agent can make this edit, but which number to bump (patch vs. minor) is
a judgment call about what actually changed — ask the user if it's not
obvious from the changes made.

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

Keep a local folder with every DMG you want listed in the update feed —
usually just the newest one is enough, since Sparkle only needs to tell
existing installs "a newer version exists," not the full history:

```bash
mkdir -p build/release
cp build/myKikau-X.Y.Z.dmg build/release/
scripts/update-appcast.sh build/release
```

This writes `build/release/appcast.xml`, using the download-url-prefix
default (`https://www.projectfive.co.ck/downloads/`) baked into the script.
If the DMG is going somewhere else this time, pass it explicitly:

```bash
scripts/update-appcast.sh build/release https://www.projectfive.co.ck/downloads/
```

## 5. Upload the DMG and appcast.xml **[HUMAN — no hosting access from here]**

Two files, two different locations on projectfive.co.ck:

- `build/myKikau-X.Y.Z.dmg` → wherever the download-url-prefix above says
  (currently `/downloads/`)
- `build/release/appcast.xml` → **must** land at `/apps/appcast.xml` exactly
  — that's `SUFeedURL` in `Info.plist`, and Sparkle only ever checks that one
  fixed URL

This is a manual upload today (FTP/hosting panel/WordPress media, whatever
projectfive.co.ck uses) — no connector is set up for it yet. If this
workflow gets run often, it's worth searching the MCP connector registry for
an FTP/SFTP or WordPress connector so this step can move to **[AGENT]** too.

## 6. Update the website content **[HUMAN — WordPress admin]**

`docs/WEBSITE_COPY.md` is the source of truth for the download page's copy.
Before this step, an agent should update that file (and the mirrored
`docs/download-page-mockup.html`) to describe what actually changed —
version number, download size, and a fresh Release Notes section
(New / Improved / Fixed). Once both docs are updated:

1. Open the WordPress editor for `/apps/mykikau/`
2. Update the primary download button's version + size
3. Update the Release Notes block with the new New/Improved/Fixed lists
4. Check the feature-highlight cards still match reality — if a feature was
   added, removed, or renamed, that grid needs to match `WEBSITE_COPY.md`'s
   feature bullet list line for line (this is exactly what drifted and
   caused the stale "Purge" mismatch during 0.2.0 — keep the two in sync
   every time, don't just edit one)

## 7. Publish a GitHub Release **[HUMAN — GitHub web UI, unless `gh` CLI + auth exists]**

1. `github.com/ProFiveCK/my-Kikau/releases/new`
2. Tag: `vX.Y.Z`, "Create new tag on publish"
3. Title: `vX.Y.Z`
4. Paste the same New/Improved/Fixed notes from step 6
5. Optionally attach the DMG as a release asset
6. Publish

If a GitHub CLI (`gh`) with an authenticated token is ever available to the
agent, steps 5–7's tag/release creation becomes scriptable:
`gh release create vX.Y.Z build/myKikau-X.Y.Z.dmg --title vX.Y.Z --notes-file notes.md`.
Not set up yet — do it via the web UI for now.

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
4. scripts/prepare-deploy.sh build/myKikau-X.Y.Z.dmg
5. Upload DMG + appcast.xml to their respective URLs        [human]
6. Update WEBSITE_COPY.md + download-page-mockup.html, then
   paste into the live WordPress page                        [human]
7. Publish a GitHub Release tagged vX.Y.Z                     [human]
8. Verify all three URLs reflect the new release              [agent]
```

## Scriptability status

The local artifact pipeline is scriptable today:

```bash
scripts/release.sh
scripts/prepare-deploy.sh build/myKikau-X.Y.Z.dmg
```

That covers build, Developer ID signing, DMG packaging, notarization, copying
the DMG into `build/release`, and regenerating `appcast.xml`.

The remaining manual parts are external-service writes:
- uploading the DMG to `projectfive.co.ck/downloads/`
- uploading `appcast.xml` to `projectfive.co.ck/apps/appcast.xml`
- updating the WordPress page at `/apps/mykikau/`
- creating the GitHub Release, unless `gh` is installed and authenticated

Those can become fully scripted once the machine has an authenticated hosting
upload method (for example SFTP/rsync/Cloudflare/WordPress CLI, depending on
how `projectfive.co.ck` is hosted) and an authenticated GitHub CLI or connector.
