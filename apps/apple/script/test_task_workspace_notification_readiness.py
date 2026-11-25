#!/usr/bin/env python3
"""Scope diagnostic samples to an already proved, owned simulator process tree."""
from pathlib import Path
from types import SimpleNamespace
import hashlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import task_workspace_notification_readiness as readiness


class OwnedReadinessDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.device = "00000000-0000-0000-0000-000000000001"
        self.app = f"/simulators/Devices/{self.device}/data/App.app/LorvexMobileApp"
        self.sampled = []
        self.controller = SimpleNamespace(ui_env={}, run=self.sample)

    def sample(self, name, command, **kwargs):
        self.assertEqual(command[0], "sample")
        self.assertEqual(command[2], "3")
        self.assertEqual(kwargs, {"timeout": 15, "check": False})
        self.sampled.append(int(command[1]))
        output = Path(command[-1])
        output.write_text("owned native sample")
        log = self.folder / (name + ".log")
        log.write_text("sample completed")
        return 0, log

    def observe(self, *, app=None, parent="launchd_sim", changed=False, inventory_timeout=False):
        calls = {}
        def run(command, **kwargs):
            self.assertEqual(kwargs["timeout"], 5)
            if command[1] == "-axo":
                if inventory_timeout:
                    raise subprocess.TimeoutExpired(command, 5)
                text = ("201 100 /sim/SpringBoard\n"
                        "202 100 /sim/usernotificationsd\n"
                        "301 300 /foreign/SpringBoard\n"
                        "302 300 /foreign/usernotificationsd\n")
            else:
                pid = int(command[2])
                calls[pid] = calls.get(pid, 0) + 1
                if pid == 200:
                    path = self.app if app is None else app
                    if changed and calls[pid] > 1:
                        path = "/foreign/LorvexMobileApp"
                    text = f"200 100 {path}\n"
                elif pid == 100:
                    text = f"100 1 /sim/{parent}\n"
                elif pid == 201:
                    text = "201 100 /sim/SpringBoard\n"
                elif pid == 202:
                    text = "202 100 /sim/usernotificationsd\n"
                else:
                    self.fail(f"Unexpected process inspection: {pid}")
            return subprocess.CompletedProcess(command, 0, text, "")
        return run

    def execute(self, observer):
        with patch.object(readiness.subprocess, "run", side_effect=observer):
            return readiness.capture_timeout_diagnostics(
                self.controller, "ipad-en", self.device, 200, 1, self.folder)

    def test_samples_only_proved_app_and_direct_owned_services_and_hashes_artifacts(self):
        result = self.execute(self.observe())
        self.assertEqual(set(self.sampled), {200, 201, 202})
        self.assertEqual(result["result"], "completed")
        for record in result["processes"]:
            artifact = record["artifact"]
            self.assertEqual(artifact["sha256"],
                             hashlib.sha256(Path(artifact["path"]).read_bytes()).hexdigest())

    def test_rejects_wrong_device_or_non_simulator_parent_without_sampling(self):
        for options in ({"app": "/foreign/LorvexMobileApp"}, {"parent": "launchd"}):
            with self.subTest(options=options):
                result = self.execute(self.observe(**options))
                self.assertEqual(result["result"], "unavailable")
                self.assertEqual(self.sampled, [])

    def test_skips_a_pid_whose_identity_changed_before_sampling(self):
        result = self.execute(self.observe(changed=True))
        self.assertNotIn(200, self.sampled)
        app = next(item for item in result["processes"] if item["role"] == "application")
        self.assertEqual(app["result"], "unavailable")
        self.assertIn("identity changed", app["reason"])

    def test_bounded_inventory_timeout_does_not_block_owned_app_sample(self):
        result = self.execute(self.observe(inventory_timeout=True))
        self.assertEqual(self.sampled, [200])
        self.assertEqual(result["serviceDiscovery"], "TimeoutExpired")


if __name__ == "__main__":
    unittest.main()
