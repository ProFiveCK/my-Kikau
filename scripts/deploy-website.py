#!/usr/bin/env python3
"""Deploy a myKikau release to projectfive.co.ck through the Hostinger API.

projectfive.co.ck is a static site built from a separate folder (default
~/MyProjects/projectfive/website-renew/site, override with --site or
MYKIKAU_SITE_DIR). The release's version and DMG size live in that site's
src/mykikau.json; this script updates it, rebuilds and checks the site, then
uploads only the files a release changes:

  downloads/myKikau-<version>.dmg   (first, so the feed never points at nothing)
  apps/index.html                   (version, size and download link)
  .htaccess                         (keeps /apps/appcast.xml, the feed URL of
                                     builds up to 0.10.2, serving the feed)
  downloads/appcast.xml             (last: this is what Sparkle reads)

Each file goes through Hostinger's upload URL (POST /api/hosting/v1/files/upload-urls)
as a TUS upload with override=true. Before uploading, the current remote text
files are saved to ~/.hermes/cache/projectfive_mykikau_backups/<timestamp>/.
Afterwards the Cloudflare cache for those URLs is purged and the public URLs
are checked: DMG checksum, feed version (at both feed URLs), page link.

Usage:
  python3 scripts/deploy-website.py                      # newest website-upload/<version>/
  python3 scripts/deploy-website.py --version 0.10.3
  python3 scripts/deploy-website.py --dry-run            # build and check the site, no uploads
  python3 scripts/deploy-website.py --only .htaccess     # upload just these built files

Credentials (never printed):
  ~/.hermes/secrets/hostinger.env   HOSTINGER_API_TOKEN (hPanel → API)
  ~/.hermes/secrets/cloudflare.env  CLOUDFLARE_API_TOKEN (needs Zone → Cache Purge), CLOUDFLARE_ZONE
                                    (zone ID or name; optional, a failed purge only warns)

Exit codes: 0 success, 1 validation error, 2 API/upload error, 3 verification error.
"""

import argparse
import datetime as dt
import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

log = logging.getLogger("deploy-website")

REPO_ROOT = Path(__file__).resolve().parent.parent
SECRETS = Path.home() / ".hermes" / "secrets"
BACKUP_BASE = Path.home() / ".hermes" / "cache" / "projectfive_mykikau_backups"
DEFAULT_SITE = Path(os.environ.get("MYKIKAU_SITE_DIR", Path.home() / "MyProjects/projectfive/website-renew/site"))

API = "https://developers.hostinger.com"
HOSTING_USERNAME = "u183486732"
DOMAIN = "projectfive.co.ck"
ORIGIN = f"https://{DOMAIN}"
# Builds up to 0.10.2 read their feed from the old www address.
LEGACY_FEED = "https://www.projectfive.co.ck/apps/appcast.xml"
FEED = f"{ORIGIN}/downloads/appcast.xml"
UA = "myKikau-deploy/1.0"
CHUNK = 10 * 1024 * 1024


class DeployError(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def load_env(path: Path) -> dict:
    if not path.exists():
        raise DeployError(f"credentials file not found: {path}", 1)
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip("'\"")
    return env


def request(url, method="GET", data=None, headers=None, timeout=120):
    """Returns (status, headers, body). HTTP errors raise DeployError without echoing credentials."""
    req = urllib.request.Request(url, data=data, method=method, headers={"User-Agent": UA, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        body = e.read()[:400].decode("utf-8", "replace")
        raise DeployError(f"HTTP {e.code} {method} {url.split('?')[0]}: {body}", 2) from None


class Hostinger:
    def __init__(self, token):
        self.auth = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        self.upload = None

    def _get(self, endpoint, **query):
        url = f"{API}/api/hosting/v1/accounts/{HOSTING_USERNAME}/domains/{DOMAIN}/{endpoint}?{urllib.parse.urlencode(query)}"
        return json.loads(request(url, headers=self.auth)[2])

    def read_text(self, path):
        """A text file's current content, or None if the API won't return it."""
        try:
            return self._get("files/content", path=path).get("content")
        except DeployError as e:
            log.warning("  could not read %s for backup: %s", path, e)
            return None

    def put(self, local: Path, dest: str):
        if self.upload is None:
            body = json.dumps({"username": HOSTING_USERNAME, "domain": DOMAIN}).encode()
            creds = json.loads(request(f"{API}/api/hosting/v1/files/upload-urls", "POST", body,
                                       {**self.auth, "Content-Type": "application/json"})[2])
            self.upload = (creds["url"].rstrip("/"), creds["auth_key"], creds["rest_auth_key"])
        base, key, rest_key = self.upload
        url = f"{base}/{urllib.parse.quote(dest)}?override=true"
        data = local.read_bytes()
        tus = {"X-Auth": key, "X-Auth-Rest": rest_key, "Tus-Resumable": "1.0.0"}
        status = request(url, "POST", b"", {**tus, "Upload-Length": str(len(data)), "Upload-Offset": "0"})[0]
        if status != 201:
            raise DeployError(f"upload of {dest} was not created (HTTP {status})", 2)
        offset = 0
        while offset < len(data):
            chunk = data[offset:offset + CHUNK]
            _, headers, _ = request(url, "PATCH", chunk, {**tus, "Upload-Offset": str(offset),
                                                          "Content-Type": "application/offset+octet-stream"})
            offset = int({k.lower(): v for k, v in headers.items()}.get("upload-offset", offset + len(chunk)))
        log.info("  ✓ %s (%d bytes)", dest, len(data))


def purge_cloudflare(urls):
    path = SECRETS / "cloudflare.env"
    if not path.exists():
        log.warning("  no %s; skipping cache purge", path)
        return
    env = load_env(path)
    auth = {"Authorization": f"Bearer {env['CLOUDFLARE_API_TOKEN']}", "Content-Type": "application/json"}
    zone = env["CLOUDFLARE_ZONE"]
    if not re.fullmatch(r"[0-9a-f]{32}", zone):
        found = json.loads(request(f"https://api.cloudflare.com/client/v4/zones?name={zone}", headers=auth)[2])["result"]
        if not found:
            raise DeployError(f"Cloudflare zone {zone} not found", 2)
        zone = found[0]["id"]
    body = json.dumps({"files": urls}).encode()
    result = json.loads(request(f"https://api.cloudflare.com/client/v4/zones/{zone}/purge_cache", "POST", body, auth)[2])
    if not result.get("success"):
        raise DeployError(f"Cloudflare purge failed: {result.get('errors')}", 2)
    log.info("  ✓ purged %d URLs", len(urls))


def latest_version():
    base = REPO_ROOT / "website-upload"
    versions = [d.name for d in base.iterdir() if d.is_dir() and re.fullmatch(r"\d+\.\d+\.\d+", d.name)] if base.exists() else []
    if not versions:
        raise DeployError("no website-upload/<version>/ folder; run scripts/prepare-deploy.sh first", 1)
    return max(versions, key=lambda v: tuple(map(int, v.split("."))))


def stage_release(version, site: Path):
    upload = REPO_ROOT / "website-upload" / version
    dmg, appcast = upload / f"myKikau-{version}.dmg", upload / "appcast.xml"
    for p in (dmg, appcast):
        if not p.exists():
            raise DeployError(f"missing {p}; run scripts/prepare-deploy.sh first", 1)
    feed = appcast.read_text()
    for marker in (f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>", f"myKikau-{version}.dmg"):
        if marker not in feed:
            raise DeployError(f"appcast.xml is missing {marker}", 1)
    downloads = site / "public" / "downloads"
    shutil.copy2(dmg, downloads / dmg.name)
    shutil.copy2(appcast, downloads / "appcast.xml")
    size = f"{dmg.stat().st_size / 1_000_000:.1f} MB"
    (site / "src" / "mykikau.json").write_text(json.dumps({"version": version, "dmgSize": size}, indent=2) + "\n")
    log.info("  staged %s (%s) and appcast.xml into %s", dmg.name, size, downloads)
    return hashlib.sha256(dmg.read_bytes()).hexdigest()


def build_site(site: Path):
    for script in ("build", "check"):
        result = subprocess.run(["npm", "run", "-s", script], cwd=site, capture_output=True, text=True)
        if result.returncode != 0:
            raise DeployError(f"site {script} failed:\n{result.stdout}{result.stderr}", 1)
        log.info("  %s", result.stdout.strip().splitlines()[-1])


def verify(version, dmg_sha):
    failures = []
    if dmg_sha:
        body = request(f"{ORIGIN}/downloads/myKikau-{version}.dmg", timeout=300)[2]
        if hashlib.sha256(body).hexdigest() != dmg_sha:
            failures.append("public DMG checksum differs from the local DMG")
    for feed in (FEED, LEGACY_FEED):
        body = request(f"{feed}?deploy-check={dt.datetime.now().timestamp():.0f}")[2]
        if f"<sparkle:shortVersionString>{version}<" not in body.decode("utf-8", "replace"):
            failures.append(f"{feed} does not list {version}")
    page = request(f"{ORIGIN}/apps/")[2].decode("utf-8", "replace")
    if f"/downloads/myKikau-{version}.dmg" not in page:
        failures.append("/apps/ does not link the new DMG")
    for f in failures:
        log.error("  ✘ %s", f)
    if failures:
        raise DeployError("verification failed", 3)
    log.info("  ✓ DMG checksum, both feed URLs and the /apps/ link all show %s", version)


def main():
    parser = argparse.ArgumentParser(description="Deploy a myKikau release to projectfive.co.ck (Hostinger)")
    parser.add_argument("--version", help="release to deploy (default: newest website-upload/<version>/)")
    parser.add_argument("--site", type=Path, default=DEFAULT_SITE, help=f"static site folder (default: {DEFAULT_SITE})")
    parser.add_argument("--dry-run", action="store_true", help="stage, build and check the site; upload nothing")
    parser.add_argument("--only", nargs="+", metavar="PATH",
                        help="upload just these files from the built site (relative to dist/), with no release staging")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    site = args.site.expanduser()
    if not (site / "scripts" / "build.mjs").exists():
        raise DeployError(f"{site} is not the Project Five site folder", 1)

    dmg_sha = None
    if args.only:
        version = None
        files = args.only
        log.info("=== Building the site ===")
        build_site(site)
    else:
        version = args.version or latest_version()
        log.info("=== Staging myKikau %s ===", version)
        dmg_sha = stage_release(version, site)
        log.info("=== Building the site ===")
        build_site(site)
        files = [f"downloads/myKikau-{version}.dmg", "apps/index.html", ".htaccess", "downloads/appcast.xml"]

    dist = site / "dist"
    missing = [f for f in files if not (dist / f).is_file()]
    if missing:
        raise DeployError(f"not in the built site: {', '.join(missing)}", 1)
    if args.dry_run:
        log.info("=== Dry run: would upload %s ===", ", ".join(files))
        return

    host = Hostinger(load_env(SECRETS / "hostinger.env")["HOSTINGER_API_TOKEN"])
    backup = BACKUP_BASE / dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    log.info("=== Backing up remote text files to %s ===", backup)
    for path in files:
        if path.endswith(".dmg"):
            continue
        content = host.read_text(path)
        if content is not None:
            (backup / path).parent.mkdir(parents=True, exist_ok=True)
            (backup / path).write_text(content)

    log.info("=== Uploading to %s ===", DOMAIN)
    for path in files:
        host.put(dist / path, path)

    log.info("=== Purging Cloudflare ===")
    urls = []
    for path in files:
        public = "/apps/" if path == "apps/index.html" else f"/{path}"
        urls += [f"{ORIGIN}{public}", f"https://www.{DOMAIN}{public}"]
    if "downloads/appcast.xml" in files or ".htaccess" in files:
        urls.append(LEGACY_FEED)
    # Cloudflare doesn't cache the pages or the feed today, and each DMG has a
    # new name, so a failed purge is reported but doesn't fail the deploy.
    try:
        purge_cloudflare(sorted(set(u for u in urls if not u.endswith("/.htaccess"))))
    except DeployError as e:
        log.warning("  ⚠ cache purge skipped: %s", e)

    if version:
        log.info("=== Verifying ===")
        verify(version, dmg_sha)
    log.info("Done.")


if __name__ == "__main__":
    try:
        main()
    except DeployError as e:
        log.error("✘ %s", e)
        sys.exit(e.code)
