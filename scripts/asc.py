"""
Minimal App Store Connect API helper.

Mints a short-lived JWT from the .p8 private key and exposes a `request()`
function for subsequent CRUD calls. Run directly to do a credentials
sanity-check (lists app records and shows the team Apple sees us as).

Credentials come from env vars or the conventional ~/.appstoreconnect path:
  ASC_KEY_ID    e.g. 72X28F2HBC
  ASC_ISSUER_ID e.g. 56d8dc2f-…
  ASC_KEY_PATH  e.g. ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import jwt  # PyJWT
import requests

API_BASE = "https://api.appstoreconnect.apple.com"

KEY_ID = os.environ.get("ASC_KEY_ID")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID")
KEY_PATH_ENV = os.environ.get("ASC_KEY_PATH")
KEY_PATH = (
    Path(KEY_PATH_ENV).expanduser()
    if KEY_PATH_ENV
    else (Path("~/.appstoreconnect/private_keys").expanduser() / f"AuthKey_{KEY_ID}.p8" if KEY_ID else None)
)

if not (KEY_ID and ISSUER_ID and KEY_PATH):
    sys.exit(
        "Missing credentials. Set ASC_KEY_ID, ASC_ISSUER_ID, and either"
        " ASC_KEY_PATH or place the .p8 at"
        " ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8"
    )


def mint_token(ttl_seconds: int = 1200) -> str:
    if not KEY_PATH.exists():
        sys.exit(f"private key not found at {KEY_PATH}")
    private_key = KEY_PATH.read_text()
    now = int(time.time())
    payload = {
        "iss": ISSUER_ID,
        "iat": now,
        "exp": now + ttl_seconds,
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": KEY_ID, "typ": "JWT"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def request(
    method: str,
    path: str,
    *,
    params: dict | None = None,
    json_body: dict | None = None,
    data: bytes | None = None,
    extra_headers: dict | None = None,
) -> requests.Response:
    headers = {"Authorization": f"Bearer {mint_token()}"}
    if json_body is not None:
        headers["Content-Type"] = "application/json"
    if extra_headers:
        headers.update(extra_headers)
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    r = requests.request(
        method,
        url,
        params=params,
        json=json_body,
        data=data,
        headers=headers,
        timeout=60,
    )
    return r


def create_bundle_id(identifier: str, name: str, platform: str = "IOS") -> str:
    """Register a bundle ID in the Apple Developer portal. Returns the
    Apple-side bundle ID resource id (a short opaque token, NOT the
    com.example.app string)."""
    body = {
        "data": {
            "type": "bundleIds",
            "attributes": {
                "identifier": identifier,
                "name": name,
                "platform": platform,
            },
        }
    }
    r = request("POST", "/v1/bundleIds", json_body=body)
    if r.status_code not in (200, 201):
        sys.exit(f"createBundleId failed {r.status_code}: {r.text}")
    return r.json()["data"]["id"]


def find_bundle_id(identifier: str) -> str | None:
    r = request(
        "GET",
        "/v1/bundleIds",
        params={"filter[identifier]": identifier, "limit": 1},
    )
    r.raise_for_status()
    items = r.json().get("data", [])
    return items[0]["id"] if items else None


def create_app(bundle_resource_id: str, *, name: str, sku: str, primary_locale: str = "en-GB") -> str:
    body = {
        "data": {
            "type": "apps",
            "attributes": {
                "bundleId": bundle_resource_id,
                "name": name,
                "primaryLocale": primary_locale,
                "sku": sku,
            },
        }
    }
    r = request("POST", "/v1/apps", json_body=body)
    if r.status_code not in (200, 201):
        sys.exit(f"createApp failed {r.status_code}: {r.text}")
    return r.json()["data"]["id"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apps", action="store_true", help="List app records")
    parser.add_argument("--bundle-ids", action="store_true", help="List registered bundle IDs")
    parser.add_argument(
        "--get",
        metavar="PATH",
        help="GET an arbitrary App Store Connect path (e.g. /v1/apps)",
    )
    parser.add_argument(
        "--create-app",
        action="store_true",
        help="Register the CycleJames bundle ID + create the App record.",
    )
    args = parser.parse_args()

    if args.create_app:
        identifier = "com.jamesbrowne.cyclejames"
        bid = find_bundle_id(identifier)
        if bid:
            print(f"bundle ID exists: {identifier} → {bid}")
        else:
            bid = create_bundle_id(identifier, "CycleJames")
            print(f"created bundle ID {identifier} → {bid}")
        app_id = create_app(bid, name="CycleJames", sku="cyclejames-ios")
        print(f"created App record: {app_id}")
        return

    if args.get:
        r = request("GET", args.get)
        print(r.status_code)
        print(json.dumps(r.json(), indent=2))
        return

    if args.bundle_ids:
        r = request("GET", "/v1/bundleIds", params={"limit": 200})
        r.raise_for_status()
        for it in r.json().get("data", []):
            attr = it["attributes"]
            print(f"{attr.get('identifier')}    {attr.get('name')}    {it['id']}")
        return

    # Default: list apps + a credentials banner.
    r = request("GET", "/v1/apps", params={"limit": 200})
    if r.status_code == 401:
        sys.exit("401 — credentials rejected. Check Key ID, Issuer ID, .p8 path.")
    r.raise_for_status()
    apps = r.json().get("data", [])
    print(f"OK — credentials valid. {len(apps)} app(s) on this team:")
    for a in apps:
        attr = a["attributes"]
        print(f"  {attr.get('bundleId'):40s}  {attr.get('name')!r}  ({a['id']})")


if __name__ == "__main__":
    main()
