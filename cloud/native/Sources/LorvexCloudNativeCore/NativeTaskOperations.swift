import GRDB
import LorvexDomain
import LorvexStore
import LorvexSync
import LorvexWorkflow

enum NativeTaskOperations {
  static func apply(_ db: Database, request: NativeRequest, taskId: TaskId,
    now: String, session: HlcSession) throws -> Bool {
    let before = try TaskResponse.loadEnrichedTaskJSON(db, taskId: taskId)
    let changed: Bool
    if request.action == "delete_task" {
      guard let row = try TaskRepo.Read.getTask(db, taskId: taskId) else {
        throw NativeError.invalidRequest("task does not exist")
      }
      if row.lifecycle.archivedAt != nil { return false }
      try TaskArchive.archiveTaskOp(db, taskId: taskId,
        version: session.nextVersionString(), now: now)
      try NativeOutbox.upsert(db, session: session, deviceId: request.deviceId,
        kind: .task, id: taskId.rawValue)
      changed = true
    } else {
      guard let dependency = request.arguments.dependsOnId else {
        throw NativeError.invalidRequest("depends_on_id is required")
      }
      _ = try TaskId.parse(dependency).get()
      guard let row = try TaskRepo.Read.getTask(db, taskId: taskId) else {
        throw NativeError.invalidRequest("task does not exist")
      }
      let adding = request.action == "add_dependency"
      let exists = try TaskUpdateDependencies.findTaskDependencies(db, taskId: taskId)
        .contains(dependency)
      // The canonical general update path advances the task version even when
      // its patch leaves the graph unchanged. These dedicated edge operations
      // promise a no-op when the requested edge state already exists.
      if adding == exists { return false }
      var effects = TaskUpdateSyncEffects()
      var changedIds: [String] = []
      let input = TaskUpdateInput(id: taskId.rawValue,
        dependsOnAdd: adding ? [dependency] : nil,
        dependsOnRemove: adding ? nil : [dependency])
      try TaskUpdate.applySingleUpdateInSavepoint(db, hlc: session, update: input,
        beforeStatus: row.core.status, now: now,
        syncEffects: &effects, depChangedIds: &changedIds)
      try TaskUpdate.revalidateDependencyCycles(db,
        depChangedIds: changedIds, errorContext: request.action)
      for id in effects.taskUpsertIds {
        try NativeOutbox.upsert(db, session: session, deviceId: request.deviceId,
          kind: .task, id: id)
      }
      for edge in effects.deletedDependencyEdges {
        let payload = DependencyEdge.buildDeletePayload(taskId: edge.taskId,
          dependsOnTaskId: edge.dependsOnTaskId, version: edge.version, createdAt: edge.createdAt)
        try OutboxEnqueue.enqueuePayloadDelete(db, entityType: EntityKind.taskDependency.asString,
          entityId: DependencyEdge.encodeEntityId(taskId: edge.taskId,
            dependsOnTaskId: edge.dependsOnTaskId), payload: payload,
          context: .init(version: session.nextVersionString(), deviceId: request.deviceId))
      }
      for id in effects.dependencyEdgeUpsertIds {
        try NativeOutbox.upsert(db, session: session, deviceId: request.deviceId,
          kind: .taskDependency, id: id)
      }
      changed = !effects.taskUpsertIds.isEmpty || !effects.deletedDependencyEdges.isEmpty
        || !effects.dependencyEdgeUpsertIds.isEmpty
    }
    if changed, AuditRetention.recordsAudit(db) {
      let after = try TaskResponse.loadEnrichedTaskJSON(db, taskId: taskId)
      try ChangelogWrite.writeChangelogRow(db, .init(
        id: EntityID.newEntityIDString(), timestamp: now,
        operation: request.action == "delete_task" ? "archive" : "update",
        entityType: EntityName.task, entityId: taskId.rawValue,
        summary: ChangelogWrite.sanitizeChangelogSummary(request.action),
        initiatedBy: "ai", mcpTool: request.action, sourceDeviceId: request.deviceId,
        beforeJson: try ChangelogWrite.encodeStateJson(before),
        afterJson: try ChangelogWrite.encodeStateJson(after)))
    }
    return changed
  }
}
