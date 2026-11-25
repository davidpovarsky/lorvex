#!/usr/bin/env python3
"""Regression coverage for complete native-unit acceptance evidence."""
from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
import xml.etree.ElementTree as ET

import verify_task_workspace_native as native


class NativeUnitEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        self.controller = native.Controller.__new__(native.Controller)
        self.controller.source = Path(native.__file__).resolve().parents[3]
        self.controller.apple = self.controller.source / "apps/apple"
        self.controller.out = self.output
        self.controller.args = SimpleNamespace(expected_sha="0" * 40)
        self.controller.receipt = {}
        self.controller.save = lambda: None
        self.controller.unit_command = lambda: ["fixture"]
        self.catalog = self.controller.unit_catalog()
        self.cases = list(self.catalog.values())
        self.log = self.output / "units.log"
        self.log.write_text(
            "\n".join(
                [f'✔ Test {label} passed after 0.001 seconds.' for label in self.catalog]
                + [f'✔ Suite "{suite}" passed after 0.001 seconds.' for suite in native.UNIT_SUITE_NAMES]
                + [f'✔ Test run with {count} tests passed after 0.001 seconds.' for count in (14, 10, 24)]
            ) + "\n"
        )
        self.controller.run = lambda *args, **kwargs: (0, self.log)

    def write_report(self, filename, cases, *, outcome=None):
        root = ET.Element("testsuites")
        suite = ET.SubElement(root, "testsuite", name="TestResults")
        for index, item in enumerate(cases):
            owner, name = item["identifier"].rsplit("/", 1)
            case = ET.SubElement(suite, "testcase", classname=owner.replace("/", "."), name=name + "()")
            if index == 0 and outcome:
                ET.SubElement(case, outcome)
        ET.ElementTree(root).write(self.output / filename)

    def assert_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Focused unit evidence is incomplete"):
            self.controller.units()
        self.assertEqual(self.controller.receipt["unit"]["result"], "failed")

    def test_accepts_complete_swift_testing_sidecar_and_all_module_summaries(self):
        self.write_report("unit-results-swift-testing.xml", self.cases)
        self.controller.units()
        receipt = self.controller.receipt["unit"]
        self.assertEqual(receipt["caseCount"], 48)
        self.assertEqual(receipt["moduleSummaryCounts"], [14, 10, 24])
        self.assertEqual(receipt["summaryCount"], 48)
        self.assertEqual(receipt["result"], "passed")
        self.assertEqual(len(receipt["xunitSources"]), 1)

    def test_combines_disjoint_xctest_and_swift_testing_reports(self):
        self.write_report("unit-results.xml", self.cases[:5])
        self.write_report("unit-results-swift-testing.xml", self.cases[5:])
        self.controller.units()
        self.assertEqual(len(self.controller.receipt["unit"]["xunitSources"]), 2)
        self.assertEqual(len(self.controller.receipt["unit"]["xunitCases"]), 48)

    def test_rejects_missing_xml_even_when_console_reports_success(self):
        self.assert_rejected()

    def test_rejects_same_count_with_duplicate_and_missing_identity(self):
        self.write_report("unit-results-swift-testing.xml", [self.cases[0], *self.cases[:-1]])
        self.assert_rejected()

    def test_rejects_duplicate_identity_across_reports(self):
        self.write_report("unit-results.xml", self.cases[:1])
        self.write_report("unit-results-swift-testing.xml", self.cases)
        self.assert_rejected()

    def test_rejects_failure_error_or_skip_in_either_report(self):
        for report in ("unit-results.xml", "unit-results-swift-testing.xml"):
            for outcome in ("failure", "error", "skipped"):
                with self.subTest(report=report, outcome=outcome):
                    for existing in self.output.glob("*.xml"):
                        existing.unlink()
                    other = "unit-results-swift-testing.xml" if report == "unit-results.xml" else "unit-results.xml"
                    self.write_report(report, self.cases[:1], outcome=outcome)
                    self.write_report(other, self.cases[1:])
                    self.assert_rejected()


if __name__ == "__main__":
    unittest.main()
