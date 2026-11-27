import Foundation
import LorvexCore
import TaskVisualizationKit
import Testing
@testable import LorvexMobile

/// Supplemental acceptance; the existing 49-case workspace catalog is kept
/// unchanged. Every mutation here reaches the canonical SQLite service.
@MainActor
struct MobileTaskMatrixTests {
  private func store(_ core: SwiftLorvexCoreService) -> MobileStore {
    MobileStore(core: core, defaults: UserDefaults(suiteName: "matrix-" + UUID().uuidString)!)
  }

  private func day(_ value: String) throws -> Date {
    try #require(PlannedDayBridge.storageDate(forLogicalDay: value))
  }

  @Test func matrixUsesCanonicalPriorityAndLogicalDueDayWithinTheExistingScope() async throws {
    let core = try SwiftLorvexCoreService.inMemory()
    let store = self.store(core)
    let list = try await core.createList(name: "Matrix scope", description: nil)
    let other = try await core.createList(name: "Other scope", description: nil)
    let outside = try await core.createTask(TaskCreateDraft(title: "Outside", listID: other.id, priority: .p1))
    var expected: [String: MobileTaskMatrixQuadrant] = [:]
    let dates: [Date?] = [try day("2026-12-01"), try day("2026-12-02"), try day("2026-12-03"), nil]
    for priority in LorvexTask.Priority.allCases {
      for (index, due) in dates.enumerated() {
        let task = try await core.createTask(TaskCreateDraft(
          title: "Priority \(priority.rawValue) date \(index)", listID: list.id, priority: priority,
          dueDate: due, plannedDate: try day(index < 2 ? "2026-12-20" : "2026-12-01")))
        expected[task.id] = priority == .p1
          ? (index < 2 ? .highDue : .highLater)
          : (index < 2 ? .normalDue : .normalLater)
      }
    }
    _ = try await store.loadVisualTaskWorkspace()
    #expect(store.taskCache[outside.id] != nil)
    let snapshot = try await store.loadVisualTaskWorkspace(listID: list.id)
    let entries = MobileTaskMatrixProjection.entries(
      snapshot: snapshot, canonicalTasks: store.taskCache, logicalDay: "2026-12-02")
    #expect(entries.count == 12)
    #expect(Set(entries.map(\.id)) == Set(snapshot.tasks.map(\.id)))
    #expect(!entries.contains { $0.id == outside.id })
    for entry in entries {
      #expect(entry.quadrant == expected[entry.id])
      #expect(entry.visual.id == entry.task.id)
      #expect(entry.task == (try await core.loadTask(id: entry.id)))
    }
    // The product's day decides the boundary even if the device is on another
    // day. Planned days above are deliberately on the opposite side.
    let future = try #require(entries.first { $0.task.priority == .p1 && $0.task.dueDate == dates[2] })
    #expect(MobileTaskMatrixProjection.quadrant(for: future.task, logicalDay: "2026-12-03") == .highDue)
  }

  @Test func matrixFieldSavesPreserveNewerPeerChangesAndIndependentFields() async throws {
    let core = try SwiftLorvexCoreService.inMemory()
    let store = self.store(core)
    let prerequisite = try await core.createTask(TaskCreateDraft(title: "Prepare"))
    let original = try await core.createTask(TaskCreateDraft(
      title: "Deliver", notes: "Original", dueDate: try day("2026-12-08"),
      plannedDate: try day("2026-12-02"), plannedTime: 540..<600, dependsOn: [prerequisite.id]))
    var priorityDraft = MobileTaskEditDraft(task: original)
    priorityDraft.priority = .p1
    priorityDraft.notes = "An unrelated stale draft must not write"
    let peerDue = try day("2026-12-09")
    _ = try await core.updateTask(TaskUpdateDraft(id: original.id, notes: "New peer note", dueDate: .set(peerDue)))
    _ = try await core.cancelTask(id: original.id)
    try await store.saveMatrixTaskField(.priority, draft: priorityDraft)
    let prioritySaved = try await core.loadTask(id: original.id)
    #expect(prioritySaved.priority == .p1)
    #expect(prioritySaved.notes == "New peer note")
    #expect(prioritySaved.status == .cancelled)
    #expect(prioritySaved.dueDate == peerDue)
    #expect(prioritySaved.plannedDate == original.plannedDate)
    #expect(prioritySaved.plannedTime == original.plannedTime)
    #expect(prioritySaved.dependsOn == original.dependsOn)

    var dueDraft = MobileTaskEditDraft(task: prioritySaved)
    dueDraft.hasDueDate = true
    dueDraft.dueDate = PlannedDayBridge.displayDate(forStorageDate: try day("2026-12-10"))
    dueDraft.priority = .p3
    try await store.saveMatrixTaskField(.due, draft: dueDraft)
    let dueSaved = try await core.loadTask(id: original.id)
    #expect(dueSaved.dueDate == (try day("2026-12-10")))
    #expect(dueSaved.priority == .p1)
    #expect(dueSaved.plannedDate == original.plannedDate)
    #expect(dueSaved.plannedTime == original.plannedTime)
    #expect(dueSaved.dependsOn == original.dependsOn)
    #expect(dueSaved.status == .cancelled)

    let unchangedDraft = MobileTaskEditDraft(task: dueSaved)
    try await store.setMatrixTaskPriority(taskID: original.id, priority: .p2)
    try await store.saveMatrixTaskField(.priority, draft: unchangedDraft)
    #expect(try await core.loadTask(id: original.id).priority == .p2)
  }

  @Test func matrixPriorityDatesAndCompletionSurviveCanonicalStoreReopen() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "lorvex-matrix-" + UUID().uuidString + ".sqlite")
    let core = SwiftLorvexCoreService(databasePath: path.path, writeInitiatorDefault: "user")
    let store = self.store(core)
    let prerequisite = try await core.createTask(TaskCreateDraft(title: "Persisted prerequisite"))
    let task = try await core.createTask(TaskCreateDraft(
      title: "Persisted Matrix task", notes: "Keep metadata", dueDate: try day("2026-12-01"),
      plannedDate: try day("2026-12-02"), plannedTime: 600..<660, dependsOn: [prerequisite.id]))
    try await store.setMatrixTaskPriority(taskID: task.id, priority: .p1)
    var plannedDraft = MobileTaskEditDraft(task: try await core.loadTask(id: task.id))
    plannedDraft.plannedDate = PlannedDayBridge.displayDate(forStorageDate: try day("2026-12-03"))
    plannedDraft.plannedTime = 660..<720
    try await store.saveMatrixTaskField(.doOn, draft: plannedDraft)
    try await store.performVisualTaskAction(.setCompleted(taskID: task.id, completed: true))

    let reopened = SwiftLorvexCoreService(databasePath: path.path, writeInitiatorDefault: "user")
    let reopenedStore = self.store(reopened)
    let saved = try await reopened.loadTask(id: task.id)
    #expect(saved.priority == .p1)
    #expect(saved.notes == task.notes)
    #expect(saved.status == .completed)
    #expect(saved.dueDate == task.dueDate)
    #expect(saved.plannedDate == (try day("2026-12-03")))
    #expect(saved.plannedTime == (660..<720))
    #expect(saved.dependsOn == [prerequisite.id])
    let snapshot = try await reopenedStore.loadVisualTaskWorkspace(rootTaskID: task.id)
    let entries = MobileTaskMatrixProjection.entries(
      snapshot: snapshot, canonicalTasks: reopenedStore.taskCache, logicalDay: "2026-12-02")
    let entry = try #require(entries.first { $0.id == task.id })
    #expect(entry.quadrant == .highDue)
    #expect(entry.visual.isCompleted)
    #expect(entry.visual.dependencyIDs == [prerequisite.id])
    try await reopenedStore.performVisualTaskAction(.setCompleted(taskID: task.id, completed: false))
    #expect(try await reopened.loadTask(id: task.id).status == .open)
    #expect(try await reopened.loadTask(id: task.id).dependsOn == [prerequisite.id])
  }
}
