#!/usr/bin/env python3
"""Owner-side TestFlight profile installation and upload verification.

Apple API key/certificate/profile material is read from CI secrets only.
No credentials or provisioning profile bytes are printed, committed or uploaded.
"""
import argparse
import base64
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

APP_ID = "6838139212"
APP_GROUP = "group.com.itorah.lorvex"
ICLOUD = "iCloud.com.itorah.lorvex"
PROFILES = {
    "main": ("com.itorah.lorvex", "DQ3BMPXDPQ", "Lorvex_AI_MAIN_AppStore_20261123"),
    "widgets": ("com.itorah.lorvex.widgets", "B3RWJK374J", "Lorvex_AI_WIDGETS_AppStore_20261123"),
    "focus": ("com.itorah.lorvex.focusfilter", "M6CWG7NMC7", "Lorvex_AI_FOCUS_AppStore_20261123"),
    "watch": ("com.itorah.lorvex.watchkitapp", "R8NKT2775T", "Lorvex_AI_WATCH_AppStore_20261123"),
    "watchwidgets": ("com.itorah.lorvex.watchkitapp.widgets", "83YX4F2RB8", "Lorvex_AI_WATCHWIDGETS_AppStore_20261123"),
}


class Client:
    def __init__(self):
        import jwt
        self.jwt = jwt
        for name in ("ASC_KEY_P8", "ASC_KEY_ID", "ASC_ISSUER_ID", "APPLE_TEAM_ID"):
            if not os.environ.get(name):
                raise RuntimeError("Missing GitHub secret: " + name)
        self.key = base64.b64decode(os.environ["ASC_KEY_P8"], validate=True).decode()
        self.key_id = os.environ["ASC_KEY_ID"]
        self.issuer = os.environ["ASC_ISSUER_ID"]
        self.team = os.environ["APPLE_TEAM_ID"]

    def request(self, suffix):
        now = int(time.time())
        token = self.jwt.encode(
            {"iss": self.issuer, "iat": now - 10, "exp": now + 600, "aud": "appstoreconnect-v1"},
            self.key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"},
        )
        req = urllib.request.Request(
            "https://api.appstoreconnect.apple.com/v1/" + suffix,
            headers={"Authorization": "Bearer " + token, "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=35) as res:
                return res.status, json.load(res)
        except urllib.error.HTTPError as exc:
            raw = exc.read(3000)
            try:
                errors = json.loads(raw).get("errors", [])
                clean = [{key: item.get(key) for key in ("code", "title", "status")}
                         for item in errors]
            except Exception:
                clean = []
            print("APPLE_REJECTED", suffix.split("?")[0], exc.code, clean, flush=True)
            return exc.code, {}


def install(client):
    folder = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"
    folder.mkdir(parents=True, exist_ok=True)
    for role, (bundle, resource_id, name) in PROFILES.items():
        code, response = client.request("profiles/" + resource_id)
        if code != 200:
            raise RuntimeError(f"Could not download Apple profile {role}")
        attrs = response["data"]["attributes"]
        if attrs.get("name") != name or attrs.get("profileState") != "ACTIVE":
            raise RuntimeError(f"Unexpected or inactive signing profile for {role}")
        data = base64.b64decode(attrs["profileContent"], validate=True)
        with tempfile.NamedTemporaryFile(suffix=".mobileprovision", delete=True) as file:
            file.write(data)
            file.flush()
            decoded = subprocess.run(
                ["security", "cms", "-D", "-i", file.name],
                capture_output=True, timeout=30,
            )
        if decoded.returncode:
            raise RuntimeError(f"Apple CMS signature could not be decoded for {role}")
        profile = plistlib.loads(decoded.stdout)
        ent = profile["Entitlements"]
        if profile["TeamIdentifier"][0] != client.team:
            raise RuntimeError(f"Wrong Apple Team in {role}")
        if ent.get("application-identifier") != client.team + "." + bundle:
            raise RuntimeError(f"Wrong application-identifier for {role}")
        if ent.get("get-task-allow") is not False:
            raise RuntimeError(f"Not an App Store distribution profile for {role}")
        if APP_GROUP not in ent.get("com.apple.security.application-groups", []):
            raise RuntimeError(f"App Group missing from {role}")
        if "ProvisionedDevices" in profile or "ProvisionsAllDevices" in profile:
            raise RuntimeError(f"Wrong provisioning method for {role}")
        expires = profile["ExpirationDate"]
        now = dt.datetime.now(expires.tzinfo) if expires.tzinfo else dt.datetime.utcnow()
        if expires <= now:
            raise RuntimeError(f"Expired profile for {role}")
        if role == "main":
            if ICLOUD not in ent.get("com.apple.developer.icloud-container-identifiers", []):
                raise RuntimeError("Main profile missing CloudKit container")
            icloud_services = ent.get("com.apple.developer.icloud-services", [])
            if isinstance(icloud_services, str):
                icloud_services = [icloud_services]
            if not any(service in icloud_services for service in ("CloudKit", "*")):
                raise RuntimeError("Main profile missing CloudKit service")
            if ent.get("aps-environment") != "production":
                raise RuntimeError("Main profile missing production push")
        destination = folder / (profile["UUID"] + ".mobileprovision")
        destination.write_bytes(data)
        destination.chmod(0o600)
        print("APP_STORE_PROFILE_VALIDATED", role, bundle, name, flush=True)
    print("ALL_FIVE_APP_STORE_PROFILES_INSTALLED", flush=True)


def verify(client, version, timeout):
    deadline = time.monotonic() + timeout
    last_state = None
    while True:
        query = urllib.parse.urlencode({"filter[app]": APP_ID, "limit": "100", "sort": "-uploadedDate"})
        code, response = client.request("builds?" + query)
        if code != 200:
            raise RuntimeError("Unable to read TestFlight build list")
        for build in response.get("data", []):
            attrs = build.get("attributes", {})
            if attrs.get("version") != version:
                continue
            state = attrs.get("processingState", "UNKNOWN")
            if state != last_state:
                print("TESTFLIGHT_BUILD_FOUND", build["id"], version, state, flush=True)
                last_state = state
            if state in ("VALID", "COMPLETE"):
                print("TESTFLIGHT_BUILD_AVAILABLE", build["id"], version, flush=True)
                return
            if state in ("FAILED", "INVALID"):
                raise RuntimeError("Apple rejected the build: " + state)
        if time.monotonic() >= deadline:
            raise RuntimeError("Upload submitted, but TestFlight build processing has not completed")
        time.sleep(25)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("install-profiles")
    verify_cmd = sub.add_parser("verify-upload")
    verify_cmd.add_argument("--build", default="171")
    verify_cmd.add_argument("--timeout-seconds", type=int, default=1100)
    args = parser.parse_args()
    try:
        client = Client()
        if args.cmd == "install-profiles":
            install(client)
        else:
            verify(client, args.build, args.timeout_seconds)
    except Exception as e:
        print("LORVEX_SIGNING_ERROR", type(e).__name__, str(e)[:200], file=sys.stderr)
        sys.exit(1)
