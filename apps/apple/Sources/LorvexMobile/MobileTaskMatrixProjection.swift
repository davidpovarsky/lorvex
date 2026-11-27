import Foundation
import LorvexCore
import TaskVisualizationKit

/// A transient grouping of the current canonical workspace, never another
/// task inventory. Planned work days are independent of external deadlines.
enum MobileTaskMatrixQuadrant: String, CaseIterable, Identifiable, Sendable {
  case highDue, highLater, normalDue, normalLater

  var id: String { rawValue }
  var isHighPriority: Bool { self == .highDue || self == .highLater }
  var isDue: Bool { self == .highDue || self == .normalDue }
}

struct MobileTaskMatrixEntry: Identifiable {
  let task: LorvexTask
  let visual: VisualTask
  let quadrant: MobileTaskMatrixQuadrant
  var id: LorvexTask.ID { task.id }
}

@MainActor
enum MobileTaskMatrixProjection {
  static func quadrant(for task: LorvexTask, logicalDay: String) -> MobileTaskMatrixQuadrant {
    // Both operands are canonical Gregorian day labels. Comparing instants in
    // the device timezone would misclassify a due day around local midnight.
    let isDue = task.dueDate.map {
      LorvexDateFormatters.ymdUTC.string(from: $0) <= logicalDay
    } ?? false
    switch (task.priority == .p1, isDue) {
    case (true, true): return .highDue
    case (true, false): return .highLater
    case (false, true): return .normalDue
    case (false, false): return .normalLater
    }
  }

  static func entries(
    snapshot: TaskWorkspaceSnapshot, canonicalTasks: [LorvexTask.ID: LorvexTask],
    logicalDay: String
  ) -> [MobileTaskMatrixEntry] {
    snapshot.tasks.compactMap { visual in
      guard let task = canonicalTasks[visual.id] else { return nil }
      return MobileTaskMatrixEntry(
        task: task, visual: visual, quadrant: quadrant(for: task, logicalDay: logicalDay))
    }
  }
}
