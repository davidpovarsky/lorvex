import Foundation
import GRDB
import LorvexDomain
import LorvexStore
import LorvexSync
import LorvexWorkflow
import XCTest
import LorvexCloudNativeCore

public final class CanonicalLifecycleTests: XCTestCase {
  private let taskId = "019ad4b2-0000-7000-8000-000000000001"
  private let now = "2026-11-23T12:00:00Z"

  private func fixture(
    recurrence: String = #"{"FREQ":"DAILY","INTERVAL":1}"#,
    related: Bool = false
  ) throws -> [SyncEnvelope] {
    let store = try Bootstrap.store()
    let date = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
    let session = HlcSession(handle: try NativeClock(deviceId: "fixture", date: date))
    return try store.writer.write { db in
      try SyncCheckpoints.set(db, key: SyncCheckpoints.keyDeviceId, value: "fixture")
      // TaskCreate requires an explicit canonical product timezone. Linux
      // system Etc/UTC is deliberately not a canonical synced preference.
      try PreferenceRepo.setPreference(db, key: PreferenceKeys.prefTimezone,
        value: "\"UTC\"", version: session.nextVersionString(), now: now)
      let input = TaskCreateInput(title: "משימה מחזורית",
        dueDate: .set("2026-11-23"),
        tags: related ? ["עברית", "Straße"] : nil,
        reminders: related ? ["2026-11-23T14:00:00Z"] : nil,
        recurrenceJson: .set(recurrence), plannedDate: .set("2026-11-23"))
      _ = try TaskCreate.createTask(db, hlc: session,
        input: CreateTaskInput(id: taskId, task: input))
      // Model cloud accounts whose timezone is supplied by the account record,
      // rather than a synced preference; the helper must honor that fallback.
      _ = try PreferenceRepo.clearPreference(db, key: PreferenceKeys.prefTimezone,
        version: session.nextVersionString())
      let report = try Outbox.enqueueAllLiveForFullResync(db)
      XCTAssertEqual(report.skipped, 0)
      return try Outbox.getPending(db).map(\.envelope)
    }
  }

  private func run(_ action: String, _ envelopes: [SyncEnvelope],
    at time: String? = nil, timezone: String? = "UTC", id: String? = nil) throws -> NativeResponse {
    try NativeExecutor.execute(.init(envelopes: envelopes, action: action,
      arguments: .init(id: id ?? taskId), now: time ?? now, timezone: timezone))
  }

  private func payload(_ envelope: SyncEnvelope) throws -> [String: JSONValue] {
    guard case .object(let object)? = JSONValue.parse(envelope.payload) else {
      throw NativeError.invalidRequest("test payload")
    }
    return object
  }

  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let object) = value else {
      throw NativeError.invalidRequest("test result")
    }
    return object
  }

  private func merged(_ baseline: [SyncEnvelope], _ response: NativeResponse) -> [SyncEnvelope] {
    var values: [String: SyncEnvelope] = [:]
    for item in baseline + response.envelopes {
      values[item.entityType.asString + ":" + item.entityId] = item
    }
    return Array(values.values)
  }

  public func testCompletionEmitsCanonicalSuccessorAndRelatedEntities() throws {
    let baseline = try fixture(related: true)
    if let path = ProcessInfo.processInfo.environment["LORVEX_NATIVE_FIXTURE_PATH"] {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(NativeRequest(envelopes: baseline, action: "complete_task",
        arguments: .init(id: taskId), now: now, timezone: "UTC"))
        .write(to: URL(fileURLWithPath: path))
    }
    let response = try run("complete_task", baseline)
    XCTAssertTrue(response.changed)
    let parent = try object(response.result.task)
    XCTAssertEqual(parent["status"], .string("completed"))
    XCTAssertEqual(parent["recurrence_rollover_state"], .string("authorized"))
    guard case .string(let successorId)? = parent["recurrence_successor_id"],
      case .string(let groupId)? = parent["recurrence_group_id"] else {
      return XCTFail("missing canonical recurrence lineage")
    }
    XCTAssertEqual(successorId, TaskRecurrenceSuccessorID.make(
      parentTaskId: taskId, recurrenceGroupId: groupId))
    let successor = try XCTUnwrap(response.envelopes.first {
      $0.entityType == .task && $0.entityId == successorId
    })
    let next = try payload(successor)
    XCTAssertEqual(next["due_date"], .string("2026-11-24"))
    XCTAssertEqual(next["status"], .string("open"))
    XCTAssertEqual(next["spawned_from_version"], parent["lifecycle_version"])
    XCTAssertTrue(response.envelopes.contains { $0.entityType == .taskTag })
    XCTAssertTrue(response.envelopes.contains { $0.entityType == .taskReminder })
    XCTAssertFalse(response.envelopes.contains { $0.entityType == .aiChangelog })
    for envelope in response.envelopes {
      XCTAssertTrue(try SyncPayloadTransportValidation.violations(for: envelope).isEmpty)
    }

    // Full wire round-trip proves the process protocol carries rich payload JSON.
    let roundTrip = try JSONDecoder().decode(NativeResponse.self,
      from: JSONEncoder().encode(response))
    XCTAssertEqual(roundTrip.envelopes, response.envelopes)
  }

  public func testRepeatCompletionIsNoopWithoutDuplicateSuccessor() throws {
    let baseline = try fixture()
    let first = try run("complete_task", baseline)
    let second = try run("complete_task", merged(baseline, first))
    XCTAssertFalse(second.changed)
    XCTAssertTrue(second.envelopes.isEmpty)
  }

  public func testReopenCancelsAndRecompletionRevivesSameSuccessor() throws {
    let baseline = try fixture(related: true)
    let completed = try run("complete_task", baseline)
    let successorId = try object(completed.result.task)["recurrence_successor_id"]
    let reopened = try run("reopen_task", merged(baseline, completed),
      at: "2026-11-23T12:01:00Z")
    XCTAssertEqual(try object(reopened.result.task)["status"], .string("open"))
    XCTAssertEqual(try object(reopened.result.task)["recurrence_rollover_state"], .string("revoked"))
    XCTAssertTrue(try reopened.envelopes.contains {
      guard $0.entityType == .task, $0.entityId != taskId else { return false }
      return try payload($0)["status"] == .string("cancelled")
    })
    let current = merged(merged(baseline, completed), reopened)
    let again = try run("complete_task", current, at: "2026-11-23T12:02:00Z")
    XCTAssertEqual(try object(again.result.task)["recurrence_successor_id"], successorId)
    let final = merged(current, again)
    let active = try final.filter {
      guard $0.entityType == .task, $0.operation == .upsert else { return false }
      return try payload($0)["status"] == .string("open")
    }
    XCTAssertEqual(active.count, 1)
  }

  public func testCountExhaustionEndsSeriesWithoutSuccessor() throws {
    let response = try run("complete_task", fixture(
      recurrence: #"{"FREQ":"DAILY","INTERVAL":1,"COUNT":1}"#))
    let parent = try object(response.result.task)
    XCTAssertEqual(parent["recurrence_rollover_state"], .string("ended"))
    XCTAssertEqual(parent["recurrence_successor_id"], .null)
    XCTAssertEqual(response.envelopes.filter { $0.entityType == .task }.count, 1)
  }

  public func testCancelSkipsOccurrenceUsingCanonicalRollover() throws {
    let response = try run("cancel_task", fixture())
    let parent = try object(response.result.task)
    XCTAssertEqual(parent["status"], .string("cancelled"))
    XCTAssertEqual(parent["completed_at"], .null)
    XCTAssertEqual(parent["recurrence_rollover_state"], .string("authorized"))
    XCTAssertEqual(response.envelopes.filter { $0.entityType == .task }.count, 2)
  }

  public func testInvalidOrIncompleteSnapshotFailsClosed() throws {
    var baseline = try fixture()
    baseline.append(baseline[0])
    XCTAssertThrowsError(try run("complete_task", baseline))
    XCTAssertThrowsError(try run("complete_task", [],
      id: "019ad4b2-0000-7000-8000-000000000099"))
    var malformed = try fixture()
    let index = try XCTUnwrap(malformed.firstIndex { $0.entityType == .task })
    malformed[index].payload = "{}"
    XCTAssertThrowsError(try run("complete_task", malformed))
  }

  public func testUnicodeTagNormalizationMatchesCanonicalContractOnLinux() {
    XCTAssertEqual(normalizeLookupKey("  Straße  "), "strasse")
    XCTAssertEqual(normalizeLookupKey("Σςσ"), "σσσ")
    XCTAssertEqual(normalizeLookupKey("İ"), "i\u{0307}")
    XCTAssertEqual(normalizeLookupKey("עברית 🧠"), "עברית 🧠")
    XCTAssertEqual(normalizeLookupKey(""), "")
    XCTAssertEqual(normalizeLookupKey("A\u{00a0}B"), "a b")
  }
  public func testCompletionAnchorUsesAccountTimezone() throws {
    let baseline = try fixture(
      recurrence: #"{"ANCHOR":"completion","FREQ":"DAILY","INTERVAL":1}"#)
    let response = try run("complete_task", baseline,
      at: "2026-11-23T23:30:00Z", timezone: "Asia/Jerusalem")
    let successor = try XCTUnwrap(response.envelopes.first {
      $0.entityType == .task && $0.entityId != taskId
    })
    XCTAssertEqual(try payload(successor)["due_date"], .string("2026-11-25"))
  }

  public func testReopenRefusesAnAdvancedSuccessor() throws {
    let baseline = try fixture()
    let first = try run("complete_task", baseline)
    guard case .string(let successorId)? = try object(first.result.task)["recurrence_successor_id"] else {
      return XCTFail("missing successor")
    }
    let second = try run("complete_task", merged(baseline, first),
      at: "2026-11-24T12:00:00Z", id: successorId)
    let advanced = merged(merged(baseline, first), second)
    XCTAssertThrowsError(try run("reopen_task", advanced, at: "2026-11-24T12:01:00Z")) { error in
      guard let lifecycle = error as? TaskLifecycleError,
        case .reopenBlockedByAdvancedSuccessor = lifecycle else {
        return XCTFail("expected canonical advanced-successor guard, got \(error)")
      }
    }
  }

}
