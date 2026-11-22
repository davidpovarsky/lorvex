#!/usr/bin/env python3
"""Structural regression tests for unsigned IPA compatibility variant."""
import importlib.util
import io
import plistlib
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).with_name("package_sideload_compat_ipa.py")
spec = importlib.util.spec_from_file_location("package_sideload_compat_ipa", SCRIPT)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class SideloadCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "full-unsigned.ipa"
        self.output = self.root / "sideload-unsigned.ipa"
        self.main = "Payload/LorvexMobileApp.app/"
        with zipfile.ZipFile(self.source, "w", compression=zipfile.ZIP_DEFLATED) as z:
            z.writestr("Payload/", b"")
            z.writestr(self.main, b"")
            z.writestr(self.main + "Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "com.lorvex.apple",
                "CFBundleExecutable": "LorvexMobileApp",
            }))
            z.writestr(self.main + "LorvexMobileApp", b"\xfe\xed\xfa\xcfmain-binary")
            z.writestr(self.main + "Frameworks/Hanlin.framework/Hanlin", b"framework-binary")
            symlink = zipfile.ZipInfo(self.main + "Frameworks/Hanlin.framework/Versions/Current")
            symlink.create_system = 3
            symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(symlink, b"A")
            z.writestr(self.main + "PlugIns/LorvexFocus.appex/Info.plist",
                       plistlib.dumps({"CFBundleIdentifier": "com.lorvex.apple.focus-filter"}))
            z.writestr(self.main + "PlugIns/Widgets.appex/Info.plist",
                       plistlib.dumps({"CFBundleIdentifier": "com.lorvex.apple.focuswidget"}))
            z.writestr(self.main + "Watch/LorvexWatch.app/Info.plist",
                       plistlib.dumps({"CFBundleIdentifier": "com.lorvex.apple.watchkitapp"}))

    def test_repack_retains_exact_core_and_removes_children(self):
        original_digest = package.digest(self.source)
        details = package.make_variant(self.source, self.output)
        self.assertTrue(self.output.exists())
        self.assertEqual(details["bundleID"], "com.lorvex.apple")
        self.assertFalse(details["bundledExtensions"])
        self.assertFalse(details["signed"])
        self.assertEqual(details["removedArchiveEntries"], 3)
        self.assertEqual(package.digest(self.source), original_digest)
        with zipfile.ZipFile(self.source) as a, zipfile.ZipFile(self.output) as b:
            remaining = b.namelist()
            self.assertIn("Payload/", remaining)
            self.assertEqual(b.read(self.main + "LorvexMobileApp"),
                             a.read(self.main + "LorvexMobileApp"))
            self.assertEqual(b.read(self.main + "Frameworks/Hanlin.framework/Hanlin"),
                             a.read(self.main + "Frameworks/Hanlin.framework/Hanlin"))
            k = self.main + "Frameworks/Hanlin.framework/Versions/Current"
            self.assertEqual(b.getinfo(k).external_attr, a.getinfo(k).external_attr)
            self.assertFalse(any("/PlugIns/" in x or "/Watch/" in x or ".appex" in x
                                 for x in remaining))
        # A signing tool can now change the main ID to e.g.
        # com.lorvex.apple.NA6HPWARQ2 without leaving a mismatched
        # child extension ID, because no children are present.
        self.assertTrue(package.validate_manifest(self.output, portable=True))

    def test_cannot_modify_in_place(self):
        with self.assertRaises(ValueError):
            package.make_variant(self.source, self.source)

    def test_already_stripped_is_not_silently_rewritten(self):
        package.make_variant(self.source, self.output)
        with self.assertRaisesRegex(ValueError, "No nested extension"):
            package.make_variant(self.output, self.root / "again.ipa")


if __name__ == "__main__":
    unittest.main()
