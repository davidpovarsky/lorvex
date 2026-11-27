#!/usr/bin/env python3
"""Exercise the actual UIKit host lifecycle code with controlled endpoint stubs.

The SwiftPM tests do not import the UIKit executable. This probe compiles its
unchanged lifecycle declarations and reminder-refresh body with Foundation,
real Swift Tasks, and deterministic UIKit/database/store endpoints. It proves
ownership and continuation behavior, not actual OS scheduling or UIKit runtime.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ.get("LORVEX_LIFECYCLE_SOURCE_ROOT", Path(__file__).resolve().parents[1]))
HOST = ROOT / "Sources" / "LorvexMobileApp"


def host_declarations(name: str) -> str:
    source = (HOST / name).read_text()
    if source.count("#if canImport(UIKit)") != 1 or source.count("#endif") != 1:
        raise AssertionError(f"Review changed conditional compilation in {name}")
    return "\n".join(
        line for line in source.splitlines()
        if not line.strip().startswith("import ")
        and line.strip() not in ("#if canImport(UIKit)", "#endif")
    )


def reminder_refresh_body() -> str:
    source = (HOST / "LorvexMobileApp.swift").read_text()
    start = source.index("await BackgroundDatabaseWork.run {",
                         source.index("func lorvexReminderBackgroundRefresh"))
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        if cursor >= len(source):
            raise AssertionError("Unbalanced reminder refresh body")
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return "@MainActor func runReminderRefresh(_ store: MobileStore) async {\n" + source[start:cursor] + "\n}"


ENDPOINTS = r"""
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct UIBackgroundTaskIdentifier: Hashable, Sendable {
  let rawValue: Int
  static let invalid = Self(rawValue: -1)
}

@MainActor enum Probe {
  static var events: [String] = []
  static var suspended = false
  static var observedCancellation = false
}

@MainActor final class UIApplication {
  enum State { case active, background }
  static let shared = UIApplication()
  var applicationState: State = .background
  private var nextID = 0
  private var history: [UIBackgroundTaskIdentifier: (String, @MainActor () -> Void)] = [:]
  private(set) var active: Set<UIBackgroundTaskIdentifier> = []
  private(set) var ended: [String: Int] = [:]

  func beginBackgroundTask(withName name: String,
                           expirationHandler: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
    nextID += 1
    let id = UIBackgroundTaskIdentifier(rawValue: nextID)
    history[id] = (name, expirationHandler)
    active.insert(id)
    return id
  }

  func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
    guard let entry = history[id] else { fatalError("Ended an unknown UIKit task") }
    ended[entry.0, default: 0] += 1
    active.remove(id)
  }

  func expire(_ name: String) {
    guard let id = history.keys.filter({ history[$0]?.0 == name })
      .max(by: { $0.rawValue < $1.rawValue }), let entry = history[id]
    else { fatalError("Missing expiration handler: \(name)") }
    entry.1()
  }
}

enum DatabaseSuspension {
  struct BackgroundAccess: Sendable {
    let begin: @Sendable () async -> Void
    let end: @Sendable () async -> Void
  }
  @MainActor static func resume() {
    Probe.suspended = false
    Probe.events.append("resume")
  }
  @MainActor @discardableResult
  static func suspend(waitingForOperations timeout: TimeInterval) -> Bool {
    Probe.suspended = true
    Probe.events.append("suspend")
    return true
  }
}

@MainActor final class MobileStore {
  var autosave: @MainActor () async -> Void = {}
  var sync: @MainActor () async -> Void = {}
  var reminders: @MainActor () async -> Void = {}
  var widget: @MainActor () async -> Void = {}
  func flushAutosaveDraftsBeforeSuspension() async { await autosave() }
  func flushCloudSyncBeforeSuspension() async { await sync() }
  func syncInBackgroundWake() async { await sync() }
  func replenishReminderWindow() async { await reminders() }
  func publishWidgetSnapshotInBackgroundWake() async { await widget() }
}

// Optional account endpoint used by the unchanged host declaration.
@MainActor final class LorvexCloudAccountState {
  var flush: @MainActor () async -> Void = {}
  func flushBeforeSuspension() async { await flush() }
}

@MainActor final class Gate {
  private var entered = false
  private var entry: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?
  func hold() async {
    entered = true
    entry?.resume()
    entry = nil
    await withCheckedContinuation { release = $0 }
  }
  func waitForEntry() async {
    if entered { return }
    await withCheckedContinuation { entry = $0 }
  }
  func open() {
    release?.resume()
    release = nil
  }
}

struct ProbeFailure: Error, CustomStringConvertible {
  let description: String
}
@MainActor func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw ProbeFailure(description: message) }
}
"""

SCENARIOS = r"""
@main struct LifecycleProbe {
  @MainActor static func main() async {
    do {
      let scenario = CommandLine.arguments[1]
      switch scenario {
      case "flush-expiry-during-autosave":
        let gate = Gate()
        let store = MobileStore()
        store.autosave = {
          Probe.events.append("autosave")
          await gate.hold() // A committed save is allowed to return late.
          Probe.observedCancellation = Task.isCancelled
          Probe.events.append("saved")
        }
        store.sync = { Probe.events.append("sync") }
        BackgroundDatabaseWork.begin() // A different handler still owns access.
        guard let work = BackgroundSyncFlush.flushThenSuspend(store: store)
        else { throw ProbeFailure(description: "No owned flush worker") }
        await gate.waitForEntry()
        UIApplication.shared.expire("Lorvex sync")
        UIApplication.shared.expire("Lorvex sync") // Repeated expiry must be harmless.
        try require(!Probe.suspended, "Expiry interrupted the other database owner")
        gate.open()
        await work.value
        try require(Probe.observedCancellation, "Expiry did not cancel its worker")
        try require(Probe.events.contains("saved"), "A completed autosave was discarded")
        try require(!Probe.events.contains("sync"), "Late autosave started sync after expiry")
        try require(!Probe.suspended, "Late worker completion released another owner")
        try require(UIApplication.shared.ended["Lorvex sync"] == 1, "Flush ended more than once")
        BackgroundDatabaseWork.end()
        try require(Probe.suspended, "Last owner did not restore suspension")

      case "flush-expiry-before-work":
        let store = MobileStore()
        store.autosave = { Probe.events.append("autosave") }
        store.sync = { Probe.events.append("sync") }
        guard let work = BackgroundSyncFlush.flushThenSuspend(store: store)
        else { throw ProbeFailure(description: "No owned flush worker") }
        UIApplication.shared.expire("Lorvex sync")
        await work.value
        try require(!Probe.events.contains("autosave") && !Probe.events.contains("sync"),
                    "Expired queued work still started")
        try require(UIApplication.shared.ended["Lorvex sync"] == 1, "Flush ended more than once")

      case "flush-success":
        let store = MobileStore()
        store.autosave = { Probe.events.append("autosave") }
        store.sync = { Probe.events.append("sync") }
        guard let work = BackgroundSyncFlush.flushThenSuspend(store: store)
        else { throw ProbeFailure(description: "No owned flush worker") }
        await work.value
        try require(Probe.events == ["resume", "autosave", "sync", "suspend"],
                    "Successful save/sync order changed: \(Probe.events)")
        try require(UIApplication.shared.active.isEmpty, "UIKit task leaked after success")

      case "foreground-expiry":
        BackgroundDatabaseWork.begin()
        UIApplication.shared.applicationState = .active
        DatabaseSuspension.resume() // The app's real foreground callback.
        UIApplication.shared.expire("Lorvex database")
        try require(!Probe.suspended, "Late expiry suspended the foreground database")
        BackgroundDatabaseWork.end()
        try require(!Probe.suspended, "Last foreground owner suspended the database")
        try require(UIApplication.shared.ended["Lorvex database"] == 1, "Budget ended twice")

      case "background-expiry":
        BackgroundDatabaseWork.begin()
        BackgroundDatabaseWork.begin()
        UIApplication.shared.expire("Lorvex database")
        try require(Probe.suspended, "Expired background budget did not release database locks")
        BackgroundDatabaseWork.end()
        BackgroundDatabaseWork.end()
        try require(UIApplication.shared.ended["Lorvex database"] == 1, "Budget ended twice")

      case "refresh-after-sync", "refresh-after-reminders", "refresh-already-cancelled", "refresh-success":
        let gate = Gate()
        let store = MobileStore()
        store.sync = {
          Probe.events.append("sync")
          if scenario == "refresh-after-sync" { await gate.hold() }
        }
        store.reminders = {
          Probe.events.append("reminders")
          if scenario == "refresh-after-reminders" { await gate.hold() }
        }
        store.widget = { Probe.events.append("widget") }
        let work = Task { @MainActor in await runReminderRefresh(store) }
        if scenario == "refresh-already-cancelled" {
          work.cancel()
        } else if scenario != "refresh-success" {
          await gate.waitForEntry()
          work.cancel()
          gate.open()
        }
        await work.value
        let phases = Probe.events.filter { ["sync", "reminders", "widget"].contains($0) }
        let expected: [String]
        switch scenario {
        case "refresh-after-sync": expected = ["sync"]
        case "refresh-after-reminders": expected = ["sync", "reminders"]
        case "refresh-already-cancelled": expected = []
        default: expected = ["sync", "reminders", "widget"]
        }
        try require(phases == expected, "Unexpected post-cancellation phases: \(phases)")
        try require(UIApplication.shared.active.isEmpty, "Refresh leaked database ownership")
        try require(Probe.suspended, "Refresh did not restore background suspension")

      default: throw ProbeFailure(description: "Unknown scenario")
      }
      print("PASS \(scenario)")
    } catch {
      print("FAIL \(error)")
      exit(1)
    }
  }
}
"""


class BackgroundLifecycleRegressions(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        swiftc = shutil.which("swiftc")
        if swiftc is None:
            raise RuntimeError("swiftc is required; this probe must not silently skip")
        cls.temporary = tempfile.TemporaryDirectory(prefix="lorvex-background-lifecycle-")
        cls.addClassCleanup(cls.temporary.cleanup)
        folder = Path(cls.temporary.name)
        source = folder / "LifecycleProbe.swift"
        source.write_text("\n".join([
            ENDPOINTS,
            host_declarations("BackgroundDatabaseWork.swift"),
            host_declarations("BackgroundSyncFlush.swift"),
            reminder_refresh_body(),
            SCENARIOS,
        ]))
        cls.binary = folder / "lifecycle-probe"
        result = subprocess.run(
            [swiftc, "-swift-version", "6", "-parse-as-library", str(source), "-o", str(cls.binary)],
            text=True, capture_output=True, timeout=45,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name: str) -> None:
        result = subprocess.run([str(self.binary), name], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"PASS {name}", result.stdout)

    def test_expired_flush_preserves_autosave_and_other_owner(self) -> None:
        self.scenario("flush-expiry-during-autosave")

    def test_expired_queued_flush_starts_no_work(self) -> None:
        self.scenario("flush-expiry-before-work")

    def test_successful_flush_balances_ownership(self) -> None:
        self.scenario("flush-success")

    def test_expiration_after_foreground_keeps_database_live(self) -> None:
        self.scenario("foreground-expiry")

    def test_expiration_in_background_still_releases_locks(self) -> None:
        self.scenario("background-expiry")

    def test_cancelled_refresh_stops_after_sync(self) -> None:
        self.scenario("refresh-after-sync")

    def test_cancelled_refresh_stops_after_reminders(self) -> None:
        self.scenario("refresh-after-reminders")

    def test_already_cancelled_refresh_starts_no_phase(self) -> None:
        self.scenario("refresh-already-cancelled")

    def test_successful_refresh_keeps_phase_order(self) -> None:
        self.scenario("refresh-success")


if __name__ == "__main__":
    unittest.main()
