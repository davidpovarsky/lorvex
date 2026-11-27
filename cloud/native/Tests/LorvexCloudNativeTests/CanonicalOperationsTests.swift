import Foundation
import GRDB
import LorvexDomain
import LorvexStore
import LorvexSync
import LorvexWorkflow
import XCTest
import LorvexCloudNativeCore

public final class CanonicalOperationsTests: XCTestCase {
  private let a = "019ad4b2-0000-7000-8000-000000000011"
  private let b = "019ad4b2-0000-7000-8000-000000000012"
  private let now = "2026-11-27T00:00:00.000Z"

  private func fixture() throws -> [SyncEnvelope] {
    let store = try Bootstrap.store()
    let session = HlcSession(handle: try NativeClock(deviceId: "fixture",
      date: Date(timeIntervalSince1970: 1_795_000_000)))
    return try store.writer.write { db in
      try SyncCheckpoints.set(db, key: SyncCheckpoints.keyDeviceId, value: "fixture")
      try PreferenceRepo.setPreference(db, key: PreferenceKeys.prefTimezone,
        value: "\"UTC\"", version: session.nextVersionString(), now: now)
      for id in [a, b] {
        _ = try TaskCreate.createTask(db, hlc: session,
          input: CreateTaskInput(id: id, task: .init(title: "משימה " + id)))
      }
      _ = try Outbox.enqueueAllLiveForFullResync(db)
      return try Outbox.getPending(db).map(\.envelope)
    }
  }
  private func run(_ action: String, _ baseline: [SyncEnvelope], id: String,
    dependency: String? = nil) throws -> NativeResponse {
    try NativeExecutor.execute(.init(envelopes: baseline, action: action,
      arguments: .init(id: id, dependsOnId: dependency), now: now, timezone: "UTC"))
  }
  private func merged(_ baseline: [SyncEnvelope], _ response: NativeResponse) -> [SyncEnvelope] {
    var values: [String: SyncEnvelope] = [:]
    for envelope in baseline + response.envelopes {
      values[envelope.entityType.asString + ":" + envelope.entityId] = envelope
    }
    return Array(values.values)
  }
  public func testDependencyAddRemoveUsesCanonicalEdgesAndTombstones() throws {
    let baseline = try fixture()
    let added = try run("add_dependency", baseline, id: a, dependency: b)
    let edge = try XCTUnwrap(added.envelopes.first { $0.entityType == .taskDependency })
    XCTAssertEqual(edge.operation, .upsert)
    XCTAssertEqual(edge.entityId, a + ":" + b)
    XCTAssertTrue(try SyncPayloadTransportValidation.violations(for: edge).isEmpty)
    let current = merged(baseline, added)
    let duplicate = try run("add_dependency", current, id: a, dependency: b)
    XCTAssertFalse(duplicate.changed)
    let removed = try run("remove_dependency", current, id: a, dependency: b)
    XCTAssertTrue(removed.envelopes.contains { $0.entityType == .taskDependency && $0.operation == .delete })
    XCTAssertFalse(try run("remove_dependency", merged(current, removed), id: a, dependency: b).changed)
  }
  public func testCyclesSelfReferencesAndMissingEndpointsFailClosed() throws {
    let baseline = try fixture()
    XCTAssertThrowsError(try run("add_dependency", baseline, id: a, dependency: a))
    XCTAssertThrowsError(try run("add_dependency", baseline, id: a,
      dependency: "019ad4b2-0000-7000-8000-000000000099"))
    let added = try run("add_dependency", baseline, id: a, dependency: b)
    XCTAssertThrowsError(try run("add_dependency", merged(baseline, added), id: b, dependency: a))
  }
  public func testDeleteMovesToTrashAndExistingCanonicalRestoreRecoversTask() throws {
    let baseline = try fixture()
    let deleted = try run("delete_task", baseline, id: a)
    let task = try XCTUnwrap(deleted.envelopes.first { $0.entityType == .task && $0.entityId == a })
    XCTAssertEqual(task.operation, .upsert)
    guard case .object(let archived)? = JSONValue.parse(task.payload) else { return XCTFail("Task payload") }
    XCTAssertEqual(archived["archived_at"], .string(now))
    XCTAssertFalse(try run("delete_task", merged(baseline, deleted), id: a).changed)

    let store = try Bootstrap.store()
    let registry = EntityApplierRegistry(appliers: EntityApplierRegistry.defaultEntityAppliers())
    let clock = try NativeClock(deviceId: "restore-fixture", date: Date(timeIntervalSince1970: 1_900_000_000))
    let session = HlcSession(handle: clock)
    try store.writer.write { db in
      for envelope in merged(baseline, deleted).sorted(by: { $0.version < $1.version }) {
        _ = try Apply.applyEnvelope(db, registry: registry, envelope: envelope)
      }
      let id = try TaskId.parse(a).get()
      try TaskArchive.restoreTaskOp(db, taskId: id, version: session.nextVersionString(), now: now)
      let restored = try XCTUnwrap(TaskRepo.Read.getTask(db, taskId: id))
      XCTAssertNil(restored.lifecycle.archivedAt)
      XCTAssertEqual(restored.core.title, "משימה " + a)
    }
  }
  public func testArchivedPrerequisiteCannotBeAdded() throws {
    let baseline = try fixture()
    let archived = try run("delete_task", baseline, id: b)
    XCTAssertThrowsError(try run("add_dependency", merged(baseline, archived), id: a, dependency: b))
  }
}
