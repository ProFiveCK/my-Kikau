#!/usr/bin/env python3
"""Deploy myKikau release artifacts to projectfive.co.ck via Plesk API.

Uploads the DMG, appcast.xml, and updates the /apps/ page app facts in the
WordPress theme's functions.php — all through the Plesk REST fs API. No
manual FTP, WordPress admin, or temporary PHP scripts needed.

The /apps/ page is rendered by the theme template page-apps.php, which reads
app data from pf_apps() in functions.php. Deploying edits that function in
place on the server so version, download URL, and copy stay in sync with the
release artifacts.

Usage:
  python3 scripts/deploy-website.py                    # deploys website-upload/<version>/
  python3 scripts/deploy-website.py --version 0.4.3     # explicit version
  python3 scripts/deploy-website.py --dry-run           # validate only, no writes
  python3 scripts/deploy-website.py --env /path/to/env  # custom env file

Environment file (~/.hermes/secrets/plesk-hostme.env):
  PLESK_HOSTME_URL=https://hostme.projectfive.co.ck
  PLESK_HOSTME_USERNAME=admin
  PLESK_HOSTME_PASSWORD=...
  PROJECTFIVE_WP_URL=https://www.projectfive.co.ck

Requirements:
  - A signed/notarized DMG in website-upload/<version>/myKikau-<version>.dmg
  - appcast.xml in website-upload/<version>/appcast.xml
  - pf-apps.php in website-upload/<version>/pf-apps.php
  - The Plesk env file with credentials

The script:
  1. Validates all artifacts exist and match expected markers
  2. Backs up the current remote appcast + theme functions.php
  3. Uploads DMG to /downloads/myKikau-<version>.dmg via Plesk fs API
  4. Uploads appcast.xml to /downloads/appcast.xml via Plesk fs API
  5. Updates pf_apps() in functions.php via Plesk fs API (in-place edit)
  6. Verifies all public URLs serve the correct content
  7. Reports pass/fail summary

Exit codes: 0=success, 1=validation error, 2=API/upload error, 3=verification error
"""

import argparse
import base64
import datetime as dt
import hashlib
import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# --- Constants ---

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ENV_PATH = Path.home() / ".hermes" / "secrets" / "plesk-hostme.env"
DOMAIN = "projectfive.co.ck"
DOWNLOAD_URL_PREFIX = "https://www.projectfive.co.ck/downloads/"
APPS_LANDING_URL = "https://www.projectfive.co.ck/apps/"
THEME_PATH = "wp-content/themes/project-five"
THEME_FUNCTIONS_PATH = f"{THEME_PATH}/functions.php"
BACKUP_BASE = Path.home() / ".hermes" / "cache" / "projectfive_mykikau_backups"


# --- Helpers ---

def load_env(path: Path) -> dict:
    """Load key=value env file."""
    if not path.exists():
        print(f"ERROR: env file not found: {path}", file=sys.stderr)
        sys.exit(1)
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def http_req(url, method="GET", data=None, headers=None, auth=None, timeout=90):
    """Make an HTTP request and return (status, headers, body_bytes)."""
    headers = dict(headers or {})
    if auth:
        token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        headers["Authorization"] = f"Basic {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl.create_default_context()) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:1200]
        raise RuntimeError(f"HTTP {e.code} {method} {url}: {body}")


def plesk_api(base, path, method="GET", data=None, headers=None, auth=None, timeout=90):
    """Call a Plesk API endpoint."""
    return http_req(base.rstrip("/") + path, method, data, headers, auth, timeout)


def plesk_fs_put(base, domain_id, path, data, auth):
    """Upload file content via Plesk fs API."""
    q = urllib.parse.urlencode({"path": path})
    return plesk_api(base, f"/api/v2/domains/{domain_id}/fs/content?{q}",
                     method="PUT", data=data,
                     headers={"Content-Type": "application/octet-stream"},
                     auth=auth, timeout=180)


def plesk_fs_chmod(base, domain_id, path, mode, auth):
    """Set file permissions via Plesk fs API."""
    q = urllib.parse.urlencode({"path": path})
    return plesk_api(base, f"/api/v2/domains/{domain_id}/fs/chmod?{q}",
                     method="PUT", data=json.dumps({"mode": mode}).encode(),
                     headers={"Content-Type": "application/json"}, auth=auth)


def plesk_fs_content(base, domain_id, path, auth):
    """Read file content via Plesk fs API (returns bytes)."""
    q = urllib.parse.urlencode({"path": path, "encoding": "base64"})
    status, headers, body = plesk_api(base, f"/api/v2/domains/{domain_id}/fs/content?{q}", auth=auth)
    txt = body.decode("utf-8", "replace")
    try:
        obj = json.loads(txt)
        if isinstance(obj, dict):
            for k in ("content", "data"):
                if k in obj:
                    return base64.b64decode(obj[k])
        if isinstance(obj, str):
            return base64.b64decode(obj)
    except Exception:
        pass
    return base64.b64decode(txt)


def plesk_fs_delete(base, domain_id, path, auth):
    """Delete file via Plesk fs API."""
    q = urllib.parse.urlencode({"path": path})
    try:
        plesk_api(base, f"/api/v2/domains/{domain_id}/fs?{q}", method="DELETE", auth=auth)
    except Exception as e:
        print(f"  WARN: delete failed: {e}")


def replace_pf_apps(server_php: str, local_pf_apps: str) -> str:
    """Replace the pf_apps() function in server functions.php with local content."""
    start = server_php.index("function pf_apps")
    depth = 0
    i = start
    while i < len(server_php):
        if server_php[i] == "{":
            depth += 1
        elif server_php[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
        i += 1
    else:
        raise RuntimeError("could not find end of pf_apps() function")
    local_pf_apps = local_pf_apps.rstrip()
    if not local_pf_apps.endswith("}"):
        local_pf_apps += "}"
    return server_php[:start] + local_pf_apps + server_php[end:]


def find_domain_id(base, domain_name, auth):
    """Look up Plesk domain ID by name."""
    q = urllib.parse.urlencode({"name": domain_name})
    status, headers, body = plesk_api(base, f"/api/v2/domains?{q}", auth=auth)
    domains = json.loads(body.decode())
    if isinstance(domains, dict) and "data" in domains:
        domains = domains["data"]
    if not domains:
        raise RuntimeError(f"Plesk domain lookup returned no results for {domain_name}")
    return domains[0]["id"]


# --- Main ---

def main():
    parser = argparse.ArgumentParser(description="Deploy myKikau release to projectfive.co.ck")
    parser.add_argument("--version", help="Version to deploy (default: auto-detect from website-upload/)")
    parser.add_argument("--env", default=str(DEFAULT_ENV_PATH), help=f"Path to Plesk env file (default: {DEFAULT_ENV_PATH})")
    parser.add_argument("--dry-run", action="store_true", help="Validate artifacts only, no uploads or page updates")
    parser.add_argument("--skip-dmg", action="store_true", help="Skip DMG upload (e.g. already uploaded)")
    parser.add_argument("--skip-appcast", action="store_true", help="Skip appcast upload")
    parser.add_argument("--skip-page", action="store_true", help="Skip theme functions.php update")
    parser.add_argument("--upload-dir", help="Override the upload directory (default: website-upload/<version>/)")
    args = parser.parse_args()

    # --- Resolve version and paths ---
    if args.version:
        version = args.version
    else:
        # Auto-detect from website-upload/ — find the newest version subdir
        upload_base = REPO_ROOT / "website-upload"
        if not upload_base.exists():
            print(f"ERROR: {upload_base} not found. Run scripts/prepare-deploy.sh first.", file=sys.stderr)
            sys.exit(1)
        versions = sorted([d.name for d in upload_base.iterdir() if d.is_dir() and re.match(r"^\d+\.\d+\.\d+$", d.name)])
        if not versions:
            print(f"ERROR: no version dirs in {upload_base}. Run scripts/prepare-deploy.sh first.", file=sys.stderr)
            sys.exit(1)
        version = versions[-1]
        print(f"Auto-detected latest version: {version}")

    upload_dir = Path(args.upload_dir) if args.upload_dir else REPO_ROOT / "website-upload" / version
    dmg_path = upload_dir / f"myKikau-{version}.dmg"
    appcast_path = upload_dir / "appcast.xml"
    pf_apps_path = upload_dir / "pf-apps.php"

    # --- Validate artifacts ---
    print(f"\n=== Validating artifacts for v{version} ===")
    missing = []
    for p in [dmg_path, appcast_path, pf_apps_path]:
        if not p.exists():
            missing.append(str(p))
    if missing:
        print(f"ERROR: missing files: {', '.join(missing)}", file=sys.stderr)
        print(f"  Run: scripts/prepare-deploy.sh", file=sys.stderr)
        sys.exit(1)

    dmg_bytes = dmg_path.read_bytes()
    appcast_text = appcast_path.read_text()
    pf_apps_text = pf_apps_path.read_text()

    dmg_name = f"myKikau-{version}.dmg"
    dmg_size = len(dmg_bytes)
    dmg_sha = hashlib.sha256(dmg_bytes).hexdigest()

    print(f"  DMG:        {dmg_name} ({dmg_size} bytes, sha256={dmg_sha[:16]}...)")
    print(f"  Appcast:    {appcast_path.name} ({len(appcast_text)} chars)")
    print(f"  pf-apps:    {pf_apps_path.name} ({len(pf_apps_text)} chars)")

    # Validate appcast markers
    appcast_markers = [
        f"myKikau-{version}.dmg",
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>",
    ]
    for marker in appcast_markers:
        if marker not in appcast_text:
            print(f"ERROR: appcast missing marker: {marker}", file=sys.stderr)
            sys.exit(1)

    # Validate pf-apps.php markers
    if "function pf_apps" not in pf_apps_text:
        print(f"ERROR: pf-apps.php missing 'function pf_apps' declaration", file=sys.stderr)
        sys.exit(1)
    pf_apps_markers = [f"myKikau-{version}", f"myKikau-{version}.dmg", f"'version'  => '{version}'"]
    for marker in pf_apps_markers:
        if marker not in pf_apps_text:
            print(f"ERROR: pf-apps.php missing marker: {marker}", file=sys.stderr)
            sys.exit(1)

    # Check pf-apps.php doesn't reference old DMG versions
    old_version_pattern = re.compile(r"myKikau-\d+\.\d+\.\d+\.dmg")
    all_versions_in_pf_apps = set(old_version_pattern.findall(pf_apps_text))
    if all_versions_in_pf_apps - {dmg_name}:
        print(f"  WARN: pf-apps.php references other DMG versions: {all_versions_in_pf_apps - {dmg_name}}")

    print(f"  All artifact markers validated.")

    if args.dry_run:
        print(f"\n=== DRY RUN: validation complete. No uploads performed. ===")
        print(f"  Ready to deploy v{version}:")
        print(f"    DMG       -> {DOWNLOAD_URL_PREFIX}{dmg_name}")
        print(f"    Appcast   -> {DOWNLOAD_URL_PREFIX}appcast.xml")
        print(f"    Theme     -> {THEME_FUNCTIONS_PATH} (pf_apps function)")
        print(f"    Apps page -> {APPS_LANDING_URL}")
        sys.exit(0)

    # --- Load credentials ---
    print(f"\n=== Loading credentials from {args.env} ===")
    env = load_env(Path(args.env))
    base = env["PLESK_HOSTME_URL"].rstrip("/")
    auth = (env["PLESK_HOSTME_USERNAME"], env["PLESK_HOSTME_PASSWORD"])
    wp_url = env.get("PROJECTFIVE_WP_URL", "https://www.projectfive.co.ck").rstrip("/")
    print(f"  Plesk API: {base}")
    print(f"  WP URL:    {wp_url}")

    # --- Create backup dir ---
    backup_dir = BACKUP_BASE / dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_dir.mkdir(parents=True, exist_ok=True)
    print(f"  Backup dir: {backup_dir}")

    # --- Find domain ID ---
    print(f"\n=== Looking up Plesk domain: {DOMAIN} ===")
    domain_id = find_domain_id(base, DOMAIN, auth)
    print(f"  Domain ID: {domain_id}")

    # --- Backup remote appcast ---
    print(f"\n=== Backing up remote state ===")
    try:
        old_appcast = plesk_fs_content(base, domain_id, "downloads/appcast.xml", auth)
        (backup_dir / "remote-appcast-before.xml").write_bytes(old_appcast)
        print(f"  Backed up remote appcast: {len(old_appcast)} bytes")
    except Exception as e:
        print(f"  WARN: appcast backup failed: {e}")

    # --- Backup remote theme functions.php ---
    server_functions_before = None
    if not args.skip_page:
        try:
            server_functions_before = plesk_fs_content(base, domain_id, THEME_FUNCTIONS_PATH, auth)
            (backup_dir / "functions-before.php").write_bytes(server_functions_before)
            print(f"  Backed up {THEME_FUNCTIONS_PATH}: {len(server_functions_before)} bytes")
        except Exception as e:
            print(f"  WARN: functions.php backup failed: {e}")

    # --- Upload DMG ---
    if not args.skip_dmg:
        print(f"\n=== Uploading DMG: {dmg_name} ({dmg_size} bytes) ===")
        plesk_fs_put(base, domain_id, f"downloads/{dmg_name}", dmg_bytes, auth)
        plesk_fs_chmod(base, domain_id, f"downloads/{dmg_name}", "0644", auth)
        print(f"  Uploaded: sha256={dmg_sha}")
    else:
        print(f"\n=== Skipping DMG upload (--skip-dmg) ===")

    # --- Upload appcast.xml ---
    if not args.skip_appcast:
        print(f"\n=== Uploading appcast.xml ===")
        appcast_bytes = appcast_path.read_bytes()
        plesk_fs_put(base, domain_id, "downloads/appcast.xml", appcast_bytes, auth)
        plesk_fs_chmod(base, domain_id, "downloads/appcast.xml", "0644", auth)
        print(f"  Uploaded: {len(appcast_bytes)} bytes sha256={hashlib.sha256(appcast_bytes).hexdigest()}")
    else:
        print(f"\n=== Skipping appcast upload (--skip-appcast) ===")

    # --- Update pf_apps() in theme functions.php ---
    if not args.skip_page:
        print(f"\n=== Updating pf_apps() in {THEME_FUNCTIONS_PATH} ===")
        # Re-read current server file (in case it changed since backup) and patch it
        current_server = plesk_fs_content(base, domain_id, THEME_FUNCTIONS_PATH, auth)
        current_text = current_server.decode("utf-8")
        patched = replace_pf_apps(current_text, pf_apps_text)
        if patched == current_text:
            print(f"  WARN: no changes applied (pf_apps function not found or identical)")
        else:
            plesk_fs_put(base, domain_id, THEME_FUNCTIONS_PATH, patched.encode("utf-8"), auth)
            print(f"  Updated: {len(patched)} bytes (was {len(current_text)} bytes)")
    else:
        print(f"\n=== Skipping theme functions.php update (--skip-page) ===")

    # --- Verify ---
    print(f"\n=== Verifying public URLs ===")
    errors = []

    # Verify DMG
    try:
        status, _, pub_dmg = http_req(f"{wp_url}/downloads/{dmg_name}", timeout=120)
        pub_hash = hashlib.sha256(pub_dmg).hexdigest()
        if len(pub_dmg) != dmg_size or pub_hash != dmg_sha:
            errors.append(f"DMG mismatch: remote {len(pub_dmg)} bytes vs local {dmg_size}")
        else:
            print(f"  DMG:      OK ({len(pub_dmg)} bytes, sha256={pub_hash[:16]}...)")
    except Exception as e:
        errors.append(f"DMG fetch failed: {e}")
        print(f"  DMG:      FAIL - {e}")

    # Verify appcast
    try:
        status, _, pub_app = http_req(f"{wp_url}/downloads/appcast.xml")
        pub_text = pub_app.decode("utf-8", "replace")
        if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in pub_text:
            errors.append(f"appcast missing version {version}")
        else:
            print(f"  Appcast:  OK (version {version} found, {len(pub_app)} bytes)")
    except Exception as e:
        errors.append(f"appcast fetch failed: {e}")
        print(f"  Appcast:  FAIL - {e}")

    # Verify apps landing page
    try:
        status, _, pub_page = http_req(APPS_LANDING_URL)
        page_text = pub_page.decode("utf-8", "replace")
        if f"myKikau-{version}.dmg" not in page_text:
            errors.append(f"apps page missing myKikau-{version}.dmg")
        elif f"Download myKikau {version}" not in page_text:
            errors.append(f"apps page missing visible 'Download myKikau {version}' text")
        else:
            print(f"  Apps page: OK (version {version} confirmed)")
    except Exception as e:
        errors.append(f"apps page fetch failed: {e}")
        print(f"  Apps page: FAIL - {e}")

    # --- Summary ---
    print(f"\n{'='*50}")
    if errors:
        print(f"DEPLOY COMPLETE WITH {len(errors)} VERIFICATION ERROR(S):")
        for e in errors:
            print(f"  - {e}")
        print(f"\nBackups saved: {backup_dir}")
        sys.exit(3)
    else:
        print(f"DEPLOY SUCCESSFUL - v{version}")
        print(f"  DMG:       {wp_url}/downloads/{dmg_name}")
        print(f"  Appcast:   {wp_url}/downloads/appcast.xml")
        print(f"  Theme:     {THEME_FUNCTIONS_PATH}")
        print(f"  Apps page: {APPS_LANDING_URL}")
        print(f"  Backups:   {backup_dir}")
        sys.exit(0)


if __name__ == "__main__":
    main()