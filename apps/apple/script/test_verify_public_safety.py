#!/usr/bin/env python3
"""Unit tests for the public-safety gate's per-line and per-path rules."""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import verify_public_safety as gate  # noqa: E402


class LineFindingsTests(unittest.TestCase):
    def test_a_placeholder_does_not_hide_a_real_address_after_it(self):
        found = gate.line_findings("a@example.com and someone@gmail.com")  # public-safety: allow
        self.assertEqual([name for name, _ in found], ["email address"])
        self.assertEqual(found[0][1], "someone@gmail.com")  # public-safety: allow

    def test_a_placeholder_alone_is_clean(self):
        self.assertEqual(gate.line_findings("write to alice@example.com"), [])

    def test_a_placeholder_home_path_does_not_hide_a_real_one(self):
        found = gate.line_findings("/Users/me/x then /Users/realperson/y")  # public-safety: allow
        self.assertEqual([text for _, text in found], ["/Users/realperson/"])  # public-safety: allow

    def test_machine_temporary_path_is_found(self):
        found = gate.line_findings("see /private/tmp/claude-501/x")  # public-safety: allow
        self.assertEqual([name for name, _ in found], ["machine temporary path"])


    def test_scaled_asset_catalog_filename_is_not_an_email(self):
        for scale in (2, 3):
            path = f'"Sources/Assets.xcassets/arxiv.imageset/arxiv-logomark-small@{scale}x.png": {{'
            self.assertEqual(gate.line_findings(path), [])

    def test_asset_filename_does_not_hide_a_real_email_on_the_same_line(self):
        line = '"Assets.xcassets/icon.imageset/icon@2x.png" someone@gmail.com'  # public-safety: allow
        self.assertEqual(gate.line_findings(line), [("email address", "someone@gmail.com")])  # public-safety: allow

    def test_scaled_address_outside_asset_catalog_is_still_reported(self):
        for line in ("someone@2x.png", '"images/icon@3x.png"'):  # public-safety: allow
            self.assertEqual([name for name, _ in gate.line_findings(line)], ["email address"])

    def test_asset_path_does_not_hide_an_extended_email_domain(self):
        line = '"Assets.xcassets/icon.imageset/person@2x.png.com"'  # public-safety: allow
        self.assertEqual([name for name, _ in gate.line_findings(line)], ["email address"])


class PathRulesTests(unittest.TestCase):
    def matches(self, path: str) -> bool:
        return any(rule.search(path) for _, rule in gate.PATH_RULES)

    def test_credential_files_are_refused(self):
        for path in ["secrets/x.env", "a/AuthKey.p8", "k.pem", "dir/server.key", "id_rsa", ".env"]:
            self.assertTrue(self.matches(path), path)

    def test_ordinary_files_are_not(self):
        for path in ["README.md", "apps/apple/Package.swift", "docs/keyboard.md"]:
            self.assertFalse(self.matches(path), path)


if __name__ == "__main__":
    unittest.main()
