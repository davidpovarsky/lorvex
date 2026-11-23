#!/usr/bin/env python3
"""Build, test and package the canonical Linux lifecycle helper."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--jobs", type=int, default=2)
parser.add_argument("--scratch-path")
parser.add_argument("--cache-path")
args = parser.parse_args()
root = Path(__file__).resolve().parent
repo = root.parents[1]
swift = shutil.which("swift")
if not swift:
    raise SystemExit("Swift toolchain is required")
common = ["--package-path", str(root), "-c", "release", "-j", str(args.jobs)]
if args.scratch_path:
    common += ["--scratch-path", str(Path(args.scratch_path).resolve())]
if args.cache_path:
    common += ["--cache-path", str(Path(args.cache_path).resolve())]
subprocess.run([swift, "build", *common, "--disable-index-store"], check=True)
tests = subprocess.run([swift, "test", *common, "--disable-testable-imports"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
print(tests.stdout, end="")
tests.check_returncode()
if not re.search(r"Executed [1-9][0-9]* tests?, with 0 failures", tests.stdout):
    raise SystemExit("No passing XCTest execution evidence; refusing packaging")
bin_dir = Path(subprocess.check_output(
    [swift, "build", *common, "--show-bin-path"], text=True).strip())
dist = root / "dist"
dist.mkdir(exist_ok=True)
binary = bin_dir / "lorvex-cloud-native"
shutil.copy2(binary, dist / binary.name)
if shutil.which("strip"):
    subprocess.run(["strip", "--strip-unneeded", str(dist / binary.name)], check=True)
resources = list(bin_dir.glob("*.resources")) + list(bin_dir.glob("*.bundle"))
if not resources:
    raise SystemExit("SwiftPM resources are missing; refusing incomplete packaging")
for source in resources:
    shutil.copytree(source, dist / source.name, dirs_exist_ok=True)
source_hashes = {}
for base in [repo / "apps/apple/core/Sources", repo / "schema", root / "Sources"]:
    for source in sorted(base.rglob("*")):
        if source.is_file():
            source_hashes[str(source.relative_to(repo))] = hashlib.sha256(source.read_bytes()).hexdigest()
manifest = {
    "source_revision": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
    "swift": subprocess.check_output([swift, "--version"], text=True).strip(),
    "source_sha256": source_hashes,
    "package_resolved_sha256": hashlib.sha256((root / "Package.resolved").read_bytes()).hexdigest(),
}
(dist / "source-manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
print("Verified deployment bundle:", dist)
