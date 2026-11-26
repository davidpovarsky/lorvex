#!/usr/bin/env python3
"""Scope diagnostic samples to an already proved, owned simulator process tree."""
from pathlib import Path
from types import SimpleNamespace
import hashlib
import ctypes
import struct
import tempfile
import unittest
from unittest.mock import Mock, patch
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

    def observe(self, *, app=None, parent="launchd_sim", changed=False,
                changed_start=False, inventory_result=None):
        calls = {}
        snapshots = {}
        records = {
            100: (1, f"/sim/{parent}"),
            200: (100, self.app if app is None else app),
            201: (100, "/sim/SpringBoard"),
            202: (100, "/sim/usernotificationsd"),
            # A child can be reparented after enumeration. The observer must
            # check its current identity instead of trusting the PID list.
            301: (300, "/foreign/SpringBoard"),
            302: (300, "/foreign/usernotificationsd"),
        }

        def pid_info(pid, flavor, argument, output, capacity):
            self.assertEqual((flavor, argument), (3, 0))
            self.assertIn(pid, records)
            calls[pid] = calls.get(pid, 0) + 1
            parent_pid, path = records[pid]
            start_seconds = 1000 + pid
            if pid == 200 and calls[pid] > 1:
                if changed:
                    path = "/foreign/LorvexMobileApp"
                if changed_start:
                    start_seconds += 1
            snapshots[pid] = path
            name = Path(path).name.encode()
            # Public macOS proc_bsdinfo ABI, independently encoded as bytes:
            # twelve uint32s, two fixed names, six 32-bit fields, two uint64s.
            raw = struct.pack(
                "<12I16s32s5Ii2Q",
                0, 2, 0, pid, parent_pid, 501, 20, 501, 20, 501, 20, 0,
                name[:15], name[:31],
                0, pid, 0, 0, 0, 0, start_seconds, 0,
            )
            self.assertEqual(capacity, len(raw))
            ctypes.memmove(output, raw, len(raw))
            return len(raw)

        def pid_path(pid, output, capacity):
            raw = snapshots[pid].encode() + b"\0"
            self.assertLessEqual(len(raw), capacity)
            ctypes.memmove(output, raw, len(raw))
            return len(raw)

        def child_pids(parent_pid, output, capacity):
            self.assertEqual(parent_pid, 100)
            self.assertEqual(capacity, ctypes.sizeof(output))
            if inventory_result is not None:
                return inventory_result
            children = [201, 202, 301, 302]
            for index, pid in enumerate(children):
                output[index] = pid
            return len(children)

        return SimpleNamespace(
            proc_pidinfo=Mock(side_effect=pid_info),
            proc_pidpath=Mock(side_effect=pid_path),
            proc_listchildpids=Mock(side_effect=child_pids),
        )

    def execute(self, observer):
        with patch("ctypes.CDLL", return_value=observer):
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
        for options in ({"changed": True}, {"changed_start": True}):
            with self.subTest(options=options):
                self.sampled.clear()
                result = self.execute(self.observe(**options))
                self.assertNotIn(200, self.sampled)
                app = next(item for item in result["processes"] if item["role"] == "application")
                self.assertEqual(app["result"], "unavailable")
                self.assertIn("identity changed", app["reason"])

    def test_unavailable_scoped_inventory_does_not_block_owned_app_sample(self):
        for inventory_result in (-1, 512):
            with self.subTest(inventory_result=inventory_result):
                self.sampled.clear()
                result = self.execute(self.observe(inventory_result=inventory_result))
                self.assertEqual(self.sampled, [200])
                self.assertEqual(result["result"], "completed")
                self.assertIn("unavailable or truncated", result["serviceDiscovery"])


if __name__ == "__main__":
    unittest.main()
