import Foundation
import GRDB
import LorvexDomain
import LorvexStore
import LorvexSync
import LorvexWorkflow

/// Transport adapter around the production canonical Apply/Workflow/Outbox APIs.
/// The only store is in-memory for this invocation; the caller atomically commits
/// the returned outbox against its account snapshot revision.
public enum NativeExecutor {
  public static func execute(_ request: NativeRequest) throws -> NativeResponse {
    guard request.deviceId.utf8.count <= SyncEnvelope.maxEnvelopeDeviceIdLen,
      !request.deviceId.isEmpty, request.envelopes.count <= 100_000 else {
      throw NativeError.invalidRequest("device identity or snapshot limit")
    }
    let taskId = try TaskId.parse(request.arguments.id).get()
    guard let timestamp = SyncTimestamp.parse(request.now ?? SyncTimestampFormat.syncTimestampNow()),
      timestamp.date.timeIntervalSince1970 >= 0 else {
      throw NativeError.invalidRequest("now must be an RFC3339 UTC timestamp")
    }
    let now = timestamp.asString
    let date = timestamp.date
    let fallbackTimezone = Timezone.normalizeProductTimezoneName(request.timezone)
    if request.timezone != nil, fallbackTimezone == nil {
      throw NativeError.invalidRequest("timezone must be a canonical product timezone")
    }

    let store = try Bootstrap.store()
    let clock = try NativeClock(deviceId: request.deviceId, date: date)
    let session = HlcSession(handle: clock)
    var identities = Set<String>()
    for envelope in request.envelopes {
      try envelope.validate().get()
      guard identities.insert(envelope.entityType.asString + ":" + envelope.entityId).inserted else {
        throw NativeError.invalidRequest("duplicate snapshot identity")
      }
      guard envelope.payloadSchemaVersion <= LorvexVersion.payloadSchemaVersion else {
        throw NativeError.incompleteSnapshot("requires a newer canonical core")
      }
      let violations = try SyncPayloadTransportValidation.violations(for: envelope)
      guard violations.isEmpty else {
        throw NativeError.incompleteSnapshot("canonical payload validation failed")
      }
      clock.observe(envelope.version)
    }

    // Hydration and any canonical convergence repairs share one transaction.
    // An unresolved reference or invariant fails the entire operation.
    try store.writer.write { db in
      try SyncCheckpoints.set(db, key: SyncCheckpoints.keyDeviceId, value: request.deviceId)
      try SyncHlcObserver.withTransactionObserver({ clock.observe($0) }) {
        try hydrate(db, envelopes: request.envelopes, clock: clock, deviceId: request.deviceId)
      }
      if let timezone = fallbackTimezone,
        !request.envelopes.contains(where: {
          $0.entityType == .preference && $0.entityId == PreferenceKeys.prefTimezone
        }) {
        // Optional host-provided account timezone is an invocation fallback,
        // never an unrequested persisted preference mutation.
        let value = String(decoding: try JSONEncoder().encode(timezone), as: UTF8.self)
        try PreferenceRepo.setPreference(db, key: PreferenceKeys.prefTimezone,
          value: value, version: session.nextVersionString(), now: now)
      }
    }

    // As in the app write surface, a future-stamped related row may require a
    // detached retry. It stays local to this invocation and cannot pin another
    // account's clock. The failed write transaction rolls back in full.
    var retried = false
    while true {
      do {
        return try store.writer.write { db in
          try SyncHlcObserver.withTransactionObserver({ clock.observe($0) }) {
            let changed = try applyAction(db, request: request, taskId: taskId,
              now: now, session: session)
            var envelopes: [SyncEnvelope] = []
            var cursor: Int64?
            while true {
              let page = try Outbox.getPendingPage(db, now: now, afterOutboxId: cursor)
              guard let end = page.lastScannedOutboxId else { break }
              guard end > (cursor ?? 0) else {
                throw NativeError.incompleteSnapshot("outbox did not advance")
              }
              envelopes.append(contentsOf: page.entries.map(\.envelope))
              cursor = end
            }
            let pending = try Int.fetchOne(db,
              sql: "SELECT COUNT(*) FROM sync_outbox WHERE synced_at IS NULL") ?? 0
            guard pending == envelopes.count else {
              throw NativeError.incompleteSnapshot("canonical outbox contains a blocked mutation")
            }
            for envelope in envelopes {
              try envelope.validate().get()
              guard try SyncPayloadTransportValidation.violations(for: envelope).isEmpty else {
                throw NativeError.incompleteSnapshot("canonical output validation failed")
              }
            }
            let payload = try OutboxEnqueue.readEntityPayloadSnapshot(
              db, entityType: EntityName.task, entityId: taskId.rawValue)
            return NativeResponse(envelopes: envelopes,
              result: .init(task: payload), changed: changed || !envelopes.isEmpty)
          }
        }
      } catch {
        guard !retried, isVersionConflict(error) else { throw error }
        retried = true
        if let floor = request.envelopes.map(\.version).max() {
          guard Hlc.hasOperationalWireSuccessor(after: floor) else { throw error }
          _ = clock.generate(dominating: floor)
        } else { throw error }
      }
    }
  }

  private static func isVersionConflict(_ error: any Error) -> Bool {
    if let error = error as? StoreError {
      switch error {
      case .staleVersion, .versionSuperseded: return true
      default: break
      }
    }
    if let error = error as? EnqueueError {
      if case .versionSuperseded = error { return true }
    }
    return false
  }

  private static func hydrate(
    _ db: Database, envelopes: [SyncEnvelope], clock: NativeClock, deviceId: String
  ) throws {
    let registry = EntityApplierRegistry(appliers: EntityApplierRegistry.defaultEntityAppliers())
    let order = Dictionary(uniqueKeysWithValues:
      EntityKind.topologicalEntityOrder.enumerated().map { ($0.element, $0.offset) })
    var pending = envelopes.sorted {
      let left = order[$0.entityType.asString] ?? Int.max
      let right = order[$1.entityType.asString] ?? Int.max
      if left != right { return left < right }
      return $0.version < $1.version
    }
    while !pending.isEmpty {
      var deferred: [SyncEnvelope] = []
      for envelope in pending {
        switch try Apply.applyEnvelope(db, registry: registry, envelope: envelope) {
        case .applied, .skipped, .remapped:
          break
        case .repairRequired(let obligation):
          try ApplyRepair.fulfill(db, obligation: obligation,
            mintVersion: { clock.generate(dominating: $0).description }, deviceId: deviceId)
        case .deferred(let reason):
          guard case .missingDependency = reason else {
            throw NativeError.incompleteSnapshot("canonical invariant requires reconciliation")
          }
          deferred.append(envelope)
        }
      }
      guard deferred.count < pending.count else {
        throw NativeError.incompleteSnapshot("unresolved related entity")
      }
      pending = deferred
    }
  }

  private static func applyAction(
    _ db: Database, request: NativeRequest, taskId: TaskId,
    now: String, session: HlcSession
  ) throws -> Bool {
    guard let row = try TaskRepo.Read.getTask(db, taskId: taskId) else {
      throw NativeError.invalidRequest("task does not exist")
    }
    if ["add_dependency", "remove_dependency", "delete_task"].contains(request.action) {
      return try NativeTaskOperations.apply(db, request: request, taskId: taskId,
        now: now, session: session)
    }
    let oldStatus = try LifecycleStatus.parsePersistedTaskStatus(taskId: taskId, raw: row.core.status)
    let version = session.nextVersionString()
    let plan: LifecycleSyncPlan
    let changed: Bool
    switch request.action {
    case "complete_task":
      let result = try LifecycleTransitions.applyCompletionTransition(
        db, taskId: taskId, now: now, reminderVersion: version)
      changed = result.updated
      plan = .from(completion: result)
    case "cancel_task":
      let result = try LifecycleTransitions.applyCancelTransition(
        db, taskId: taskId, now: now, reminderVersion: version,
        cancelSeries: false, seriesClearVersion: nil)
      changed = result.updated
      plan = .from(cancel: result)
    case "reopen_task":
      let result = try LifecycleTransitions.applyReopenTransition(
        db, taskId: taskId, oldStatus: oldStatus, now: now, reminderVersion: version)
      changed = result.updated
      plan = .from(reopen: result)
    case "start_task", "pause_task":
      let starting = request.action == "start_task"
      let target: TaskStatus = starting ? .inProgress : .open
      let required: TaskStatus = starting ? .open : .inProgress
      if oldStatus == target { return false }
      guard oldStatus == required else {
        throw NativeError.invalidRequest("lifecycle transition requires a different source status")
      }
      let result = try LifecycleTransitions.applyLifecycleTransition(
        db, taskId: taskId, oldStatus: oldStatus, newStatus: target,
        now: now, reminderVersion: version)
      changed = true
      plan = .from(transition: result)
    default:
      throw NativeError.invalidRequest("unsupported action")
    }
    if changed {
      try NativeOutbox.upsert(db, session: session, deviceId: request.deviceId,
        kind: .task, id: taskId.rawValue)
      try NativeOutbox.flush(db, session: session, deviceId: request.deviceId, plan: plan)
    }
    return changed
  }
}
