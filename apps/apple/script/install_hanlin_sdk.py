#!/usr/bin/env python3
"""Run the canonical SDK installer from the exact revision in the host lock."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.request import urlopen


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--source-cache", type=Path)
    args = parser.parse_args()
    host = Path(__file__).resolve().parents[3]
    lock = json.loads((host / "HanlinSDK.lock.json").read_text())
    revision = lock["revision"]
    if not isinstance(revision, str) or not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise SystemExit("Hanlin SDK requires an immutable full commit revision")
    arguments = ["--host-root", str(host)]
    if args.check:
        installer = host / "Vendor/HanlinSDK/Scripts/SDK/install.py"
        if not installer.is_file():
            raise SystemExit("Run apps/apple/script/install_hanlin_sdk.py to install the pinned SDK first")
        subprocess.run([sys.executable, str(installer), *arguments, "--check"], check=True)
        return
    if args.source_cache:
        arguments.extend(["--source-cache", str(args.source_cache.resolve())])
    # The implementation is fetched from the same immutable canonical revision
    # as the sources. This bootstrap intentionally vendors no SDK implementation.
    url = f"https://raw.githubusercontent.com/davidpovarsky/hanlin-ai/{revision}/Scripts/SDK/install.py"
    with urlopen(url, timeout=45) as response:
        code = response.read(2_000_001)
    if len(code) > 2_000_000:
        raise SystemExit("Unexpected SDK installer size")
    with tempfile.TemporaryDirectory(prefix="lorvex-hanlin-bootstrap-") as directory:
        installer = Path(directory) / "install.py"
        installer.write_bytes(code)
        subprocess.run([sys.executable, str(installer), *arguments], check=True)


if __name__ == "__main__":
    main()
