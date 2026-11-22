#!/usr/bin/env python3
"""Repackage the *already built* Lorvex IPA for sideloaders that rename only
the containing app's CFBundleIdentifier.

Those tools violate Apple's required parent-prefix rule when a nested
extension retains its original bundle ID. The compatibility variant keeps
the identical compiled app binary and frameworks, but EXCLUDES nested
app extensions/widgets and the Watch companion app. Never silently
strip them from a normal/release IPA, and do not label this unsigned
variant as signed or directly installable without a signer.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import os
import plistlib
from pathlib import Path
import sys
import zipfile

REMOVED_BUNDLE_DIRS = {"PlugIns", "Watch", "Extensions", "SystemExtensions"}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(2 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def app_prefix(paths: list[str]) -> str:
    roots = sorted({"/".join(name.split("/")[:2]) + "/"
                    for name in paths if len(name.split("/")) >= 3
                    and name.startswith("Payload/")
                    and name.split("/")[1].endswith(".app")})
    if len(roots) != 1:
        raise ValueError(f"Expected exactly one Payload/NAME.app, found: {roots}")
    return roots[0]


def strip_entry(name: str, prefix: str) -> bool:
    if name == "Payload/":
        return False
    if not name.startswith(prefix):
        raise ValueError(f"Unexpected IPA entry outside the primary .app: {name}")
    relative = name[len(prefix):].split("/")
    return any(component in REMOVED_BUNDLE_DIRS for component in relative)


def validate_manifest(ipa: Path, *, portable: bool) -> dict:
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA ZIP checksum validation failed")
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate archive entry")
        prefix = app_prefix(names)
        plist_key = prefix + "Info.plist"
        if plist_key not in names:
            raise ValueError("Primary Info.plist missing")
        main = plistlib.loads(archive.read(plist_key))
        bundle_id = main.get("CFBundleIdentifier")
        executable = main.get("CFBundleExecutable")
        if not isinstance(bundle_id, str) or not bundle_id:
            raise ValueError("Primary bundle identifier missing")
        if not isinstance(executable, str) or prefix + executable not in names:
            raise ValueError("Primary Mach-O executable missing")
        nested = [name for name in names if any(
            component in REMOVED_BUNDLE_DIRS for component in name[len(prefix):].split("/")
        ) or name.endswith(".appex/Info.plist")]
        if portable and nested:
            raise ValueError(f"Portable IPA still contains nested extensions: {nested[:10]}")
        if portable and any(x.endswith(".appex") for x in names):
            raise ValueError("Portable IPA still contains .appex bundles")
        return {
            "kind": "lorvex-hanlin-sideload-compat-v1" if portable else "lorvex-hanlin-full-v1",
            "artifact": ipa.name, "bytes": ipa.stat().st_size,
            "sha256": digest(ipa),
            "bundleID": bundle_id,
            "mainExecutable": executable,
            "entryCount": len(names),
            "bundledExtensions": False if portable else bool(nested),
            "removedCapabilities": ["WidgetKit extensions", "Focus Filter", "Watch companion"] if portable else [],
            "signed": False,
            "needsExternalSigning": True,
            "notes": ("The sideloading/signing service may rename only the main bundle ID; "
                      "this build has no nested app-extension IDs to mismatch. "
                      "The compiled app and embedded frameworks are retained. "
                      "This is NOT an official fully-featured signed distribution.") if portable
                     else "Full original app archive; any external signer MUST rewrite nested extension IDs consistently."
        }


def make_variant(source: Path, dest: Path) -> dict:
    if source.resolve() == dest.resolve():
        raise ValueError("Input and output must differ")
    if not source.is_file():
        raise FileNotFoundError(source)
    dest.parent.mkdir(parents=True, exist_ok=True)
    stage = dest.with_name(dest.name + ".partial")
    try:
        with zipfile.ZipFile(source, "r") as original, zipfile.ZipFile(stage, "w", allowZip64=True) as output:
            members = original.infolist()
            names = [info.filename for info in members]
            if len(names) != len(set(names)):
                raise ValueError("Duplicate source archive names")
            prefix = app_prefix(names)
            skip_count = 0
            for member in members:
                name = member.filename
                if name != "Payload/" and not name.startswith(prefix):
                    raise ValueError(f"Non-app entry in archive: {name}")
                if strip_entry(name, prefix):
                    skip_count += 1
                    continue
                # Preserve ZIP Unix permission bits and symlink metadata
                # without unpacking/reconstructing frameworks.
                output.writestr(copy.copy(member), original.read(member))
        if skip_count == 0:
            raise ValueError("No nested extension files were found: wrong source IPA?")
        details = validate_manifest(stage, portable=True)
        os.replace(stage, dest)
        details["artifact"] = dest.name
        details["removedArchiveEntries"] = skip_count
        return details
    finally:
        stage.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    full = validate_manifest(args.source, portable=False)
    portable = make_variant(args.source, args.output)
    manifest = {
        "source": full, "sideloadCompatible": portable,
        "validated": True, "validation": (
            "ZIP CRCs checked, original executable and primary bundle preserved, "
            "nested app-extension / Watch payload absent, SHA256 recorded; "
            "physical device installation NOT tested"),
        "important": (
            "Use sideloadCompatible only with a signing tool that re-signs the main app. "
            "It intentionally excludes widgets, Focus Filter and the Watch app; "
            "for full features use a correctly signed distribution that preserves "
            "the parent prefix for all embedded extension identifiers.")
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
