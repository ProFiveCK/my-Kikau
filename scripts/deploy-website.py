#!/usr/bin/env python3
"""Deploy myKikau release artifacts to projectfive.co.ck via Plesk API.

Uploads the DMG, appcast.xml, and updates the WordPress product page — all
through the Plesk REST API + a temporary self-deleting PHP script for the
WordPress DB update. No manual FTP or WordPress admin needed.

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
  PROJECTFIVE_WP_USERNAME=admin
  PROJECTFIVE_WP_PASSWORD=...

Requirements:
  - A signed/notarized DMG in website-upload/<version>/myKikau-<version>.dmg
  - appcast.xml in website-upload/<version>/appcast.xml
  - wordpress-page.html in website-upload/<version>/wordpress-page.html
  - The Plesk env file with credentials

The script:
  1. Validates all artifacts exist and match expected markers
  2. Backs up the current remote appcast + WordPress page
  3. Uploads DMG to /downloads/myKikau-<version>.dmg via Plesk fs API
  4. Uploads appcast.xml to /downloads/appcast.xml via Plesk fs API
  5. Updates WordPress page (ID 61) via a temporary PHP script (auto-deleted)
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
import secrets
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
WORDPRESS_PAGE_ID = 61
DOWNLOAD_URL_PREFIX = "https://www.projectfive.co.ck/downloads/"
PRODUCT_PAGE_URL = "https://www.projectfive.co.ck/apps/mykikau/"
APPS_LANDING_URL = "https://www.projectfive.co.ck/apps/"
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


def call_temp_php(url, token, action, content=None):
    """Call the temporary PHP script for WordPress page backup/update."""
    data = {"token": token, "action": action, "page_id": str(WORDPRESS_PAGE_ID)}
    if content is not None:
        data["content_b64"] = base64.b64encode(content.encode()).decode()
    status, headers, body = http_req(url, method="POST",
                                     data=urllib.parse.urlencode(data).encode(),
                                     headers={"Content-Type": "application/x-www-form-urlencoded"},
                                     timeout=120)
    obj = json.loads(body.decode("utf-8", "replace"))
    if not obj.get("ok"):
        raise RuntimeError(f"PHP error: {obj}")
    return obj


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
    parser.add_argument("--skip-page", action="store_true", help="Skip WordPress page update")
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
    page_path = upload_dir / "wordpress-page.html"

    # --- Validate artifacts ---
    print(f"\n=== Validating artifacts for v{version} ===")
    missing = []
    for p in [dmg_path, appcast_path, page_path]:
        if not p.exists():
            missing.append(str(p))
    if missing:
        print(f"ERROR: missing files: {', '.join(missing)}", file=sys.stderr)
        print(f"  Run: scripts/prepare-deploy.sh", file=sys.stderr)
        sys.exit(1)

    dmg_bytes = dmg_path.read_bytes()
    appcast_text = appcast_path.read_text()
    page_html = page_path.read_text()

    dmg_name = f"myKikau-{version}.dmg"
    dmg_size = len(dmg_bytes)
    dmg_sha = hashlib.sha256(dmg_bytes).hexdigest()

    print(f"  DMG:     {dmg_name} ({dmg_size} bytes, sha256={dmg_sha[:16]}...)")
    print(f"  Appcast: {appcast_path.name} ({len(appcast_text)} chars)")
    print(f"  Page:    {page_path.name} ({len(page_html)} chars)")

    # Validate appcast markers
    appcast_markers = [
        f"myKikau-{version}.dmg",
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>",
    ]
    for marker in appcast_markers:
        if marker not in appcast_text:
            print(f"ERROR: appcast missing marker: {marker}", file=sys.stderr)
            sys.exit(1)

    # Validate page markers
    page_markers = [f"myKikau-{version}", f"myKikau-{version}.dmg"]
    for marker in page_markers:
        if marker not in page_html:
            print(f"ERROR: wordpress page missing marker: {marker}", file=sys.stderr)
            sys.exit(1)

    # The production WordPress page is a content fragment using the established
    # .mk-* design system. Reject standalone design mockups so a release-text
    # update cannot accidentally replace the live page layout again.
    if 'class="mk-page"' not in page_html or "<!DOCTYPE html>" in page_html:
        print(
            "ERROR: wordpress page must be the production .mk-page fragment, "
            "not a standalone design mockup",
            file=sys.stderr,
        )
        sys.exit(1)

    # Check page doesn't reference old versions
    old_version_pattern = re.compile(r"myKikau-\d+\.\d+\.\d+\.dmg")
    all_versions_in_page = set(old_version_pattern.findall(page_html))
    if all_versions_in_page - {dmg_name}:
        print(f"  WARN: page references other DMG versions: {all_versions_in_page - {dmg_name}}")

    print(f"  All artifact markers validated.")

    if args.dry_run:
        print(f"\n=== DRY RUN: validation complete. No uploads performed. ===")
        print(f"  Ready to deploy v{version}:")
        print(f"    DMG      -> {DOWNLOAD_URL_PREFIX}{dmg_name}")
        print(f"    Appcast  -> {DOWNLOAD_URL_PREFIX}appcast.xml")
        print(f"    WP page  -> {PRODUCT_PAGE_URL} (page ID {WORDPRESS_PAGE_ID})")
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

    # --- Deploy temporary PHP script for WordPress page backup/update ---
    token = secrets.token_urlsafe(32)
    php_name = f".pf_mykikau_update_{secrets.token_hex(8)}.php"
    php_code = f"""<?php
header('Content-Type: application/json');
$expected = {token!r};
$page_id = {WORDPRESS_PAGE_ID};
if (!isset($_POST['token']) || !hash_equals($expected, $_POST['token'])) {{
    http_response_code(403);
    echo json_encode(['ok'=>false,'error'=>'forbidden']);
    exit;
}}
require_once __DIR__ . '/wp-load.php';
global $wpdb;
$action = $_POST['action'] ?? '';
if ($action === 'backup') {{
    $row = $wpdb->get_row($wpdb->prepare(
        "SELECT post_title, post_content FROM {{$wpdb->posts}} WHERE ID=%d", $page_id
    ), ARRAY_A);
    echo json_encode(['ok'=>true,'title'=>$row['post_title'],
        'content_b64'=>base64_encode($row['post_content']),
        'length'=>strlen($row['post_content'])]);
    exit;
}}
if ($action === 'update') {{
    $content = base64_decode($_POST['content_b64'] ?? '', true);
    if ($content === false) {{
        echo json_encode(['ok'=>false,'error'=>'bad_base64']); exit;
    }}
    $now = current_time('mysql');
    $now_gmt = current_time('mysql', 1);
    $res = $wpdb->update($wpdb->posts,
        ['post_content'=>$content, 'post_modified'=>$now, 'post_modified_gmt'=>$now_gmt],
        ['ID'=>$page_id], ['%s','%s','%s'], ['%d']);
    if ($res === false) {{
        echo json_encode(['ok'=>false,'error'=>'db_update_failed']); exit;
    }}
    clean_post_cache($page_id);
    echo json_encode(['ok'=>true,'updated_rows'=>$res,'length'=>strlen($content)]);
    exit;
}}
echo json_encode(['ok'=>false,'error'=>'unknown_action']);
"""
    temp_url = f"{wp_url}/{php_name}"

    # Upload the temp PHP script
    plesk_fs_put(base, domain_id, php_name, php_code.encode(), auth)
    plesk_fs_chmod(base, domain_id, php_name, "0644", auth)
    print(f"  Temp PHP script deployed: {php_name}")

    try:
        # --- Backup WordPress page ---
        if not args.skip_page:
            try:
                b = call_temp_php(temp_url, token, "backup")
                old_page = base64.b64decode(b["content_b64"])
                (backup_dir / "wordpress-page-before.html").write_bytes(old_page)
                print(f"  Backed up WordPress page {WORDPRESS_PAGE_ID}: {len(old_page)} bytes")
            except Exception as e:
                print(f"  WARN: WordPress page backup failed: {e}")

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

        # --- Update WordPress page ---
        if not args.skip_page:
            print(f"\n=== Updating WordPress page {WORDPRESS_PAGE_ID} ===")
            u = call_temp_php(temp_url, token, "update", page_html)
            print(f"  Updated: length={u.get('length')} rows={u.get('updated_rows')}")
        else:
            print(f"\n=== Skipping WordPress page update (--skip-page) ===")

    finally:
        # Always clean up the temp PHP script
        plesk_fs_delete(base, domain_id, php_name, auth)
        print(f"  Temp PHP script deleted.")

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

    # Verify WordPress page
    try:
        status, _, pub_page = http_req(PRODUCT_PAGE_URL)
        page_text = pub_page.decode("utf-8", "replace")
        if f"myKikau-{version}.dmg" not in page_text:
            errors.append(f"product page missing myKikau-{version}.dmg")
        elif f"myKikau {version}" not in page_text:
            errors.append(f"product page missing visible myKikau {version} text")
        else:
            print(f"  WP page:  OK (version {version} confirmed)")
    except Exception as e:
        errors.append(f"product page fetch failed: {e}")
        print(f"  WP page:  FAIL - {e}")

    # Verify temp script is gone
    try:
        http_req(temp_url, method="POST",
                data=urllib.parse.urlencode({"token": token, "action": "backup"}).encode(),
                headers={"Content-Type": "application/x-www-form-urlencoded"}, timeout=20)
        errors.append("temp PHP script still reachable")
        print(f"  Temp PHP: FAIL - still reachable!")
    except Exception:
        print(f"  Temp PHP: OK (removed)")

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
        print(f"  DMG:      {wp_url}/downloads/{dmg_name}")
        print(f"  Appcast:  {wp_url}/downloads/appcast.xml")
        print(f"  Page:     {PRODUCT_PAGE_URL}")
        print(f"  Backups:  {backup_dir}")
        sys.exit(0)


if __name__ == "__main__":
    main()