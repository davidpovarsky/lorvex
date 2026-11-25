"""Hash the complete native application and XCTest runtime closure."""
from __future__ import annotations
import hashlib
from pathlib import Path
import plistlib

MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
BUNDLE_SUFFIXES = {".app", ".appex", ".framework", ".xctest", ".bundle"}

def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def capture(application: Path, manifest_path: Path) -> dict:
    application = application.resolve()
    products = manifest_path.resolve().parent
    manifest = plistlib.loads(manifest_path.read_bytes())
    targets = [
        target for config in manifest.get("TestConfigurations", [])
        for target in config.get("TestTargets", [])
    ]
    if not targets:
        targets = [
            value for value in manifest.values()
            if isinstance(value, dict) and "TestBundlePath" in value
        ]
    if not targets:
        raise RuntimeError("No test runtime paths in the original xctestrun.")
    roots = {str(application): "application"}
    test_bundles = set()
    for target in targets:
        host = Path(target["TestHostPath"].replace("__TESTROOT__", str(products))).resolve()
        target_app = Path(target["UITargetAppPath"].replace("__TESTROOT__", str(products))).resolve()
        test = Path(target["TestBundlePath"].replace("__TESTROOT__", str(products))
                    .replace("__TESTHOST__", str(host))).resolve()
        if target_app != application or not host.is_dir() or not test.is_dir():
            raise RuntimeError("Unexpected application, test host, or XCTest bundle path.")
        if not host.is_relative_to(products) or not test.is_relative_to(host):
            raise RuntimeError("Test runtime escaped its recorded product directory.")
        roots[str(host)] = "test-runner"
        test_bundles.add(str(test))
    binaries = {}
    bundles = []
    for root_text in sorted(roots):
        root = Path(root_text)
        if not root.is_dir():
            raise RuntimeError("Missing runtime bundle: " + str(root))
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            if not path.resolve().is_relative_to(root):
                raise RuntimeError("Embedded runtime file escaped its bundle: " + str(path))
            with path.open("rb") as stream:
                is_macho = stream.read(4) in MACHO_MAGIC
            if is_macho:
                binaries[str(path)] = digest(path)
            if path.name != "Info.plist" or path.parent.suffix not in BUNDLE_SUFFIXES:
                continue
            info = plistlib.loads(path.read_bytes())
            executable_name = info.get("CFBundleExecutable")
            if not executable_name:
                continue
            if Path(executable_name).name != executable_name:
                raise RuntimeError("Invalid CFBundleExecutable: " + str(path))
            executable = path.parent / executable_name
            if not executable.is_file():
                raise RuntimeError("Bundle executable is missing: " + str(executable))
            bundles.append({
                "path": str(path.parent), "kind": path.parent.suffix,
                "infoPlistPath": str(path), "infoPlistSHA256": digest(path),
                "bundleIdentifier": info.get("CFBundleIdentifier"),
                "executableName": executable_name, "executablePath": str(executable),
                "executableSHA256": digest(executable),
            })
    for bundle in bundles:
        if binaries.get(bundle["executablePath"]) != bundle["executableSHA256"]:
            raise RuntimeError("Declared bundle executable is not a captured Mach-O.")
    declared = {item["path"] for item in bundles}
    if not set(roots).issubset(declared) or not test_bundles.issubset(declared):
        raise RuntimeError("Application, runner, or XCTest executable was not captured.")
    return {
        "schemaVersion": 1,
        "roots": [{"role": roots[path], "path": path} for path in sorted(roots)],
        "testBundlePaths": sorted(test_bundles),
        "bundles": sorted(bundles, key=lambda item: item["path"]),
        "machOBinaries": dict(sorted(binaries.items())),
    }
