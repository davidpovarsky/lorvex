import Foundation
import LorvexCore
import TaskVisualizationKit

/// The visual workspace projects the canonical task graph. No task data is
/// stored by the visualization libraries; their IDs are the original task IDs.
@MainActor
enum MobileTaskWorkspaceProjection {
  static func snapshot(
    tasks: [LorvexTask], blockedIDs: Set<String>, isTruncated: Bool,
    title: String, listNames: [String: String] = [:]
  ) -> TaskWorkspaceSnapshot {
    let visibleIDs = Set(tasks.map(\.id))
    var warnings: [String] = []
    if isTruncated { warnings.append(MobileTaskWorkspaceCopy.truncated) }
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
      // TaskVisualTone supplies the kit's semantic lane tokens.
      lanes: [
        .init(id: "open", title: MobileTaskWorkspaceCopy.open, tone: TaskVisualTone.blue),
        .init(id: "in_progress", title: MobileTaskWorkspaceCopy.inProgress, tone: TaskVisualTone.orange),
        .init(id: "someday", title: MobileTaskWorkspaceCopy.someday, tone: TaskVisualTone.purple),
        .init(id: "completed", title: MobileTaskWorkspaceCopy.completed, tone: TaskVisualTone.green),
        .init(id: "cancelled", title: MobileTaskWorkspaceCopy.cancelled, tone: TaskVisualTone.neutral)
      ],
      warnings: warnings, allowsPlannedDate: true)
  }
}

enum MobileTaskWorkspaceCopy {
  static var title: String {
    String(localized: "visualTasks.title", defaultValue: "Task workspace",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var subtitle: String {
    String(localized: "visualTasks.subtitle", defaultValue: "Explore dependencies, boards and your task timeline.",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var open: String {
    String(localized: "visualTasks.open", defaultValue: "Open",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var inProgress: String {
    String(localized: "visualTasks.inProgress", defaultValue: "In Progress",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var someday: String {
    String(localized: "visualTasks.someday", defaultValue: "Someday",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var completed: String {
    String(localized: "visualTasks.completed", defaultValue: "Completed",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var cancelled: String {
    String(localized: "visualTasks.cancelled", defaultValue: "Cancelled",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var truncated: String {
    String(localized: "visualTasks.truncated", defaultValue: "This graph reached its display limit. Open a list or a specific task to focus the workspace.",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var hiddenDependencies: String {
    String(localized: "visualTasks.hiddenDependencies", defaultValue: "Some prerequisites are outside this view. Blocking rules still use the complete task graph.",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var failed: String {
    String(localized: "visualTasks.failed", defaultValue: "The change could not be saved. Review the task and try again.",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var unavailable: String {
    String(localized: "visualTasks.unavailable", defaultValue: "The task workspace could not be loaded.",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var retry: String {
    String(localized: "visualTasks.retry", defaultValue: "Try again",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var refresh: String {
    String(localized: "visualTasks.refresh", defaultValue: "Refresh workspace",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var add: String {
    String(localized: "visualTasks.add", defaultValue: "Add Task",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var titlePrompt: String {
    String(localized: "visualTasks.titlePrompt", defaultValue: "Task title",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var notes: String {
    String(localized: "visualTasks.notes", defaultValue: "Notes",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var close: String {
    String(localized: "common.done", defaultValue: "Done",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var cancel: String {
    String(localized: "common.cancel", defaultValue: "Cancel",
      table: "Localizable", bundle: MobileL10n.bundle)
  }
}
