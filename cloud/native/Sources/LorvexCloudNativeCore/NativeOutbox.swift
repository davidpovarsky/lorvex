import GRDB
import LorvexDomain
import LorvexStore
import LorvexSync
import LorvexWorkflow

/// Mirrors the app's thin OutboxLifecycleFlush adapter. The canonical
/// LifecycleSyncPlan owns the inventory; OutboxEnqueue owns all wire encoding,
/// version stamping, forward-compatible shadows, coalescing and tombstones.
enum NativeOutbox {
  static func upsert(_ db: Database, session: HlcSession, deviceId: String,
    kind: EntityKind, id: String) throws {
    let payload = try OutboxEnqueue.readEntityPayloadSnapshot(
      db, entityType: kind.asString, entityId: id)
    try OutboxEnqueue.enqueuePayloadUpsert(db, entityType: kind.asString,
      entityId: id, payload: payload,
      context: .init(version: session.nextVersionString(), deviceId: deviceId,
        registerIntent: .inferredLocalMutation(entityType: kind, from: payload)))
  }

  static func flush(_ db: Database, session: HlcSession, deviceId: String,
    plan: LifecycleSyncPlan) throws {
    for status in [plan.status, plan.successorCancel] {
      for id in status.cancelledReminderIds {
        try upsert(db, session: session, deviceId: deviceId, kind: .taskReminder, id: id)
      }
      for edge in status.deletedDependencyEdges {
        let payload = DependencyEdge.buildDeletePayload(taskId: edge.taskId,
          dependsOnTaskId: edge.dependsOnTaskId, version: edge.version, createdAt: edge.createdAt)
        try OutboxEnqueue.enqueuePayloadDelete(db, entityType: EntityKind.taskDependency.asString,
          entityId: DependencyEdge.encodeEntityId(taskId: edge.taskId,
            dependsOnTaskId: edge.dependsOnTaskId),
          payload: payload, context: .init(version: session.nextVersionString(), deviceId: deviceId))
      }
    }
    for id in plan.reopenedReminderIds {
      try upsert(db, session: session, deviceId: deviceId, kind: .taskReminder, id: id)
    }
    if let id = plan.spawnedSuccessorId {
      try upsert(db, session: session, deviceId: deviceId, kind: .task, id: id)
    }
    for edge in plan.spawnedSuccessorTagEdges {
      let payload = PayloadLoaders.taskTagPayload(taskId: edge.taskId, tagId: edge.tagId,
        version: edge.version, createdAt: edge.createdAt)
      try OutboxEnqueue.enqueuePayloadUpsert(db, entityType: EntityKind.taskTag.asString,
        entityId: edge.taskId + ":" + edge.tagId, payload: payload,
        context: .init(version: session.nextVersionString(), deviceId: deviceId))
    }
    for id in plan.spawnedSuccessorChecklistItemIds {
      try upsert(db, session: session, deviceId: deviceId, kind: .taskChecklistItem, id: id)
    }
    for id in plan.spawnedSuccessorReminderIds {
      try upsert(db, session: session, deviceId: deviceId, kind: .taskReminder, id: id)
    }
    for id in plan.cancelledSuccessorIds {
      try upsert(db, session: session, deviceId: deviceId, kind: .task, id: id)
    }
  }
}
