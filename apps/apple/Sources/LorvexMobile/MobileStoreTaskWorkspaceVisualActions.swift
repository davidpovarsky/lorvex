import Foundation
import LorvexCore
import TaskVisualizationKit

extension MobileStore {
  /// Include independent tasks as well as the scoped dependency neighbourhood.
  /// Inactive tasks stay visible so their existing records can be reopened.
  public func loadVisualTaskWorkspace(
    rootTaskID: String? = nil, listID: String? = nil
  ) async throws -> TaskWorkspaceSnapshot {
    let rootTitle: String?
    if let rootTaskID { rootTitle = try await core.loadTask(id: rootTaskID).title }
    else { rootTitle = nil }
    if let listID { _ = try await core.loadListDetail(id: listID, limit: 1, offset: 0) }
    let workspace = try await core.loadTaskWorkspace(rootTaskID: rootTaskID, listID: listID)
    let tasks = workspace.tasks
    let blocked = try await core.blockedTaskIDs(in: tasks)
    try Task.checkCancellation()
    cacheTasks(tasks)
    let names = Dictionary((lists?.lists ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    return MobileTaskWorkspaceProjection.snapshot(
      tasks: tasks, blockedIDs: blocked, isTruncated: workspace.truncated,
      title: rootTitle ?? listID.flatMap { names[$0] } ?? MobileTaskWorkspaceCopy.title,
      listNames: names)
  }

  /// The component receives success only after the existing mutation pipeline
  /// confirms the durable write and refreshes local state. The canonical
  /// widget/reminder/badge tail is queued without keeping the editor busy;
  /// overlapping writes coalesce into a latest-state pass. Never persist a
  /// canvas-local model.
  public func performVisualTaskAction(_ action: TaskWorkspaceAction) async throws {
    let success: Bool
    switch action {
    case .setCompleted(let id, let completed):
      success = completed
        ? await completeTask(id, publication: .deferred)
        : await reopenTask(id, publication: .deferred)
    case .moveTask(let id, let laneID):
      switch laneID {
      case "open":
        let task = try await core.loadTask(id: id)
        success = task.status == .inProgress
          ? await pauseTask(id, publication: .deferred)
          : await reopenTask(id, publication: .deferred)
      case "in_progress":
        // Preserve the canonical transition: finished/Someday tasks must first
        // be reopened. A rejected drop never makes a partial two-step mutation.
        success = await startTask(id, publication: .deferred)
      case "someday": success = await markTaskSomeday(id, publication: .deferred)
      case "completed": success = await completeTask(id, publication: .deferred)
      case "cancelled": success = await cancelTask(id, publication: .deferred)
      default: throw MobileTaskWorkspaceActionError(message: MobileTaskWorkspaceCopy.failed)
      }
    case .setDueDate(let id, let date):
      success = await mutateTaskReturningTask(id: id, publication: .deferred) {
        try await core.updateTask(TaskUpdateDraft(
          id: id,
          dueDate: date.map { .set(PlannedDayBridge.storageDate(forLocalInstant: $0)) } ?? .clear))
      }
    case .setPlannedDate(let id, let date):
      success = await mutateTaskReturningTask(id: id, publication: .deferred) {
        try await core.updateTask(TaskUpdateDraft(
          id: id,
          plannedDate: date.map { .set(PlannedDayBridge.storageDate(forLocalInstant: $0)) } ?? .clear))
      }
    case .addDependency(let prerequisiteID, let dependentID):
      success = await changeVisualDependency(
        prerequisiteID: prerequisiteID, dependentID: dependentID, adding: true)
    case .removeDependency(let prerequisiteID, let dependentID):
      success = await changeVisualDependency(
        prerequisiteID: prerequisiteID, dependentID: dependentID, adding: false)
    case .openTask, .createTask:
      // Navigation and editor presentation belong to the live view.
      throw MobileTaskWorkspaceActionError(message: MobileTaskWorkspaceCopy.failed)
    }
    guard success else {
      throw MobileTaskWorkspaceActionError(message: errorMessage ?? MobileTaskWorkspaceCopy.failed)
    }
  }

  private func changeVisualDependency(
    prerequisiteID: String, dependentID: String, adding: Bool
  ) async -> Bool {
    await mutateTaskReturningTask(id: dependentID, publication: .deferred) {
      // Read fresh inside the mutation operation. Only this field is patched;
      // title, dates and other metadata edited by a peer remain untouched.
      let current = try await core.loadTask(id: dependentID)
      var ids = current.dependsOn
      if adding {
        if !ids.contains(prerequisiteID) { ids.append(prerequisiteID) }
      } else {
        ids.removeAll { $0 == prerequisiteID }
      }
      return try await core.updateTask(TaskUpdateDraft(id: dependentID, dependsOn: ids))
    }
  }

  /// Canonical priority write used by Matrix and the live cloud acceptance
  /// probe. Priority has no implicit relationship with due or planned dates.
  public func setMatrixTaskPriority(taskID: LorvexTask.ID, priority: LorvexTask.Priority) async throws {
    let success = await mutateTaskReturningTask(id: taskID, publication: .deferred) {
      try await core.updateTask(TaskUpdateDraft(id: taskID, priority: priority))
    }
    guard success else {
      throw MobileTaskWorkspaceActionError(message: errorMessage ?? MobileTaskWorkspaceCopy.failed)
    }
  }

  /// Save exactly the Matrix field the user opened, based on the editor's
  /// baseline differences. A no-change save is a no-op even if a peer changed
  /// that field while the sheet was open. All other fields remain omitted.
  func saveMatrixTaskField(_ field: MobileTaskField, draft: MobileTaskEditDraft) async throws {
    let changes = draft.coreUpdateDraft
    let patch: TaskUpdateDraft
    switch field {
    case .priority:
      if let priority = changes.priority {
        try await setMatrixTaskPriority(taskID: draft.id, priority: priority)
      }
      return
    case .due:
      patch = TaskUpdateDraft(id: draft.id, dueDate: changes.dueDate)
    case .doOn:
      // A changed planned day owns its time. Preserve the existing canonical
      // editor rule rather than losing a deliberately selected time slot.
      patch = TaskUpdateDraft(id: draft.id, plannedDate: changes.plannedDate, plannedTime: changes.plannedTime)
    default:
      throw MobileTaskWorkspaceActionError(message: MobileTaskWorkspaceCopy.failed)
    }
    guard patch != TaskUpdateDraft(id: draft.id) else { return }
    let success = await mutateTaskReturningTask(id: draft.id, publication: .deferred) {
      try await core.updateTask(patch)
    }
    guard success else {
      throw MobileTaskWorkspaceActionError(message: errorMessage ?? MobileTaskWorkspaceCopy.failed)
    }
  }
}

struct MobileTaskWorkspaceActionError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
