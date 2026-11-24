import Foundation
import LorvexCore
import TaskVisualizationKit

/// The visual workspace projects the canonical task graph. No task data is
/// stored by the visualization libraries; their IDs are the original task IDs.
@MainActor
enum MobileTaskWorkspaceProjection {
  static func snapshot(
    graph: DependencyGraph, tasks: [LorvexTask], blockedIDs: Set<String>,
    title: String, listNames: [String: String] = [:]
  ) -> TaskWorkspaceSnapshot {
    let visibleIDs = Set(tasks.map(\.id))
    var warnings: [String] = []
    if graph.truncated { warnings.append(MobileTaskWorkspaceCopy.truncated) }
    if tasks.contains(where: { !Set($0.dependsOn).isSubset(of: visibleIDs) }) {
      warnings.append(MobileTaskWorkspaceCopy.hiddenDependencies)
    }
    return TaskWorkspaceSnapshot(
      title: title,
      tasks: tasks.map { task in
        let parts = [task.listID.flatMap { listNames[$0] }, task.priority.rawValue].compactMap { $0 }
        return VisualTask(
          id: task.id, title: task.title, subtitle: parts.joined(separator: " · "),
          laneID: task.status.rawValue, isCompleted: task.status == .completed,
          isBlocked: blockedIDs.contains(task.id),
          isReady: task.status.isActionable && !blockedIDs.contains(task.id),
          dueDate: task.dueDate.map { PlannedDayBridge.displayDate(forStorageDate: $0) },
          plannedDate: task.plannedDate.map { PlannedDayBridge.displayDate(forStorageDate: $0) },
          estimatedMinutes: task.estimatedMinutes, dependencyIDs: task.dependsOn,
          subtaskCount: task.checklistItems.count,
          completedSubtaskCount: task.checklistItems.filter { $0.completedAt != nil }.count)
      },
      lanes: [
        .init(id: "open", title: MobileTaskWorkspaceCopy.open, tone: .blue),
        .init(id: "in_progress", title: MobileTaskWorkspaceCopy.inProgress, tone: .orange),
        .init(id: "someday", title: MobileTaskWorkspaceCopy.someday, tone: .purple),
        .init(id: "completed", title: MobileTaskWorkspaceCopy.completed, tone: .green),
        .init(id: "cancelled", title: MobileTaskWorkspaceCopy.cancelled, tone: .neutral)
      ],
      warnings: warnings, allowsPlannedDate: true)
  }
}

enum MobileTaskWorkspaceCopy {
  static var title: String { text("visualTasks.title", "Task workspace") }
  static var subtitle: String { text("visualTasks.subtitle", "Explore dependencies, boards and your task timeline.") }
  static var open: String { text("visualTasks.open", "Open") }
  static var inProgress: String { text("visualTasks.inProgress", "In Progress") }
  static var someday: String { text("visualTasks.someday", "Someday") }
  static var completed: String { text("visualTasks.completed", "Completed") }
  static var cancelled: String { text("visualTasks.cancelled", "Cancelled") }
  static var truncated: String { text("visualTasks.truncated", "This graph reached its display limit. Open a list or a specific task to focus the workspace.") }
  static var hiddenDependencies: String { text("visualTasks.hiddenDependencies", "Some prerequisites are outside this view. Blocking rules still use the complete task graph.") }
  static var failed: String { text("visualTasks.failed", "The change could not be saved. Review the task and try again.") }
  static var unavailable: String { text("visualTasks.unavailable", "The task workspace could not be loaded.") }
  static var retry: String { text("visualTasks.retry", "Try again") }
  static var refresh: String { text("visualTasks.refresh", "Refresh workspace") }
  static var add: String { text("visualTasks.add", "Add Task") }
  static var titlePrompt: String { text("visualTasks.titlePrompt", "Task title") }
  static var notes: String { text("visualTasks.notes", "Notes") }
  static var close: String { text("common.close", "Close") }
  static var cancel: String { text("common.cancel", "Cancel") }

  private static func text(_ key: String, _ fallback: String) -> String {
    MobileL10n.bundle.localizedString(forKey: key, value: fallback, table: "Localizable")
  }
}
