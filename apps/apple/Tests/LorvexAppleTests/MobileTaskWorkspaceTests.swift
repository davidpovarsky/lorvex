import Foundation
import LorvexCore
import LorvexWidgetKitSupport
import TaskVisualizationKit
import Testing
@testable import LorvexMobile

@MainActor
struct MobileTaskWorkspaceTests {
  private func fixture() throws -> (SwiftLorvexCoreService, MobileStore) {
    let core = try SwiftLorvexCoreService.inMemory()
    let defaults = UserDefaults(suiteName: "visual-tasks-" + UUID().uuidString)!
    return (core, MobileStore(core: core, defaults: defaults))
  }

  @Test func dependenciesUseOriginalIDsAndRejectCyclesWithoutLosingOtherFields() async throws {
    let (core, store) = try fixture()
    let first = try await core.createTask(TaskCreateDraft(title: "Prerequisite", notes: "Keep first notes"))
    let second = try await core.createTask(TaskCreateDraft(title: "Dependent", notes: "Keep second notes"))
    try await store.performVisualTaskAction(.addDependency(
      prerequisiteID: first.id, dependentID: second.id))

    let snapshot = try await store.loadVisualTaskWorkspace()
    let node = try #require(snapshot.tasks.first { $0.id == second.id })
    #expect(node.dependencyIDs == [first.id])
    #expect(node.isBlocked)
    #expect(!node.isReady)
    #expect(snapshot.tasks.first { $0.id == first.id }?.isReady == true)
    #expect(Set(snapshot.tasks.map(\.id)) == Set([first.id, second.id]))
    #expect(try await core.loadTask(id: second.id).notes == "Keep second notes")

    var rejected = false
    do {
      try await store.performVisualTaskAction(.addDependency(
        prerequisiteID: second.id, dependentID: first.id))
    } catch { rejected = true }
    #expect(rejected)
    #expect(try await core.loadTask(id: first.id).dependsOn.isEmpty)
    #expect(try await core.loadTask(id: second.id).dependsOn == [first.id])

    try await store.performVisualTaskAction(.removeDependency(
      prerequisiteID: first.id, dependentID: second.id))
    #expect(try await core.loadTask(id: second.id).dependsOn.isEmpty)
    #expect(try await core.loadTask(id: second.id).notes == "Keep second notes")
  }

  @Test func boardUsesCanonicalBlockedStartAndDoesNotPartiallyReopen() async throws {
    let (core, store) = try fixture()
    let first = try await core.createTask(TaskCreateDraft(title: "Prepare"))
    let next = try await core.createTask(TaskCreateDraft(title: "Run", dependsOn: [first.id]))
    var rejected = false
    do { try await store.performVisualTaskAction(.moveTask(taskID: next.id, laneID: "in_progress")) }
    catch { rejected = true }
    #expect(rejected)
    #expect(try await core.loadTask(id: next.id).status == .open)

    try await store.performVisualTaskAction(.setCompleted(taskID: first.id, completed: true))
    try await store.performVisualTaskAction(.moveTask(taskID: next.id, laneID: "in_progress"))
    #expect(try await core.loadTask(id: next.id).status == .inProgress)
    try await store.performVisualTaskAction(.setCompleted(taskID: next.id, completed: true))
    try await store.performVisualTaskAction(.setCompleted(taskID: first.id, completed: false))
    // Reopening a prerequisite never silently uncompletes downstream work.
    #expect(try await core.loadTask(id: next.id).status == .completed)
    rejected = false
    do { try await store.performVisualTaskAction(.moveTask(taskID: next.id, laneID: "in_progress")) }
    catch { rejected = true }
    #expect(rejected)
    #expect(try await core.loadTask(id: next.id).status == .completed)
  }

  @Test func cancelledAndSomedayRemainEditableButAreNotReady() async throws {
    let (core, store) = try fixture()
    let later = try await core.createTask(TaskCreateDraft(title: "Later"))
    let cancelled = try await core.createTask(TaskCreateDraft(title: "Cancelled"))
    _ = try await core.markTaskSomeday(id: later.id)
    _ = try await core.cancelTask(id: cancelled.id)
    let snapshot = try await store.loadVisualTaskWorkspace()
    #expect(snapshot.tasks.count == 2)
    #expect(snapshot.tasks.allSatisfy { !$0.isReady && !$0.isReadOnly })
    try await store.performVisualTaskAction(.moveTask(taskID: later.id, laneID: "open"))
    let reopened = try await store.loadVisualTaskWorkspace()
    #expect(reopened.tasks.first { $0.id == later.id }?.isReady == true)
  }

  @Test func workspaceIncludesIndependentTasksAndKeepsListAndRootScopes() async throws {
    let (core, store) = try fixture()
    let list = try await core.createList(name: "Workspace", description: nil)
    let other = try await core.createList(name: "Elsewhere", description: nil)
    let standalone = try await core.createTask(TaskCreateDraft(title: "Independent", listID: list.id))
    let prerequisite = try await core.createTask(TaskCreateDraft(title: "External prerequisite", listID: other.id))
    let dependent = try await core.createTask(TaskCreateDraft(
      title: "Scoped dependent", listID: list.id, dependsOn: [prerequisite.id]))
    let unrelated = try await core.createTask(TaskCreateDraft(title: "Unrelated", listID: other.id))
    let archived = try await core.createTask(TaskCreateDraft(title: "Trashed", listID: list.id))
    _ = try await core.archiveTask(id: archived.id)

    let all = try await store.loadVisualTaskWorkspace()
    #expect(Set(all.tasks.map(\.id)) == Set([standalone.id, prerequisite.id, dependent.id, unrelated.id]))
    let scoped = try await store.loadVisualTaskWorkspace(listID: list.id)
    #expect(Set(scoped.tasks.map(\.id)) == Set([standalone.id, prerequisite.id, dependent.id]))
    #expect(scoped.tasks.first { $0.id == dependent.id }?.isBlocked == true)
    let rooted = try await store.loadVisualTaskWorkspace(rootTaskID: dependent.id)
    #expect(Set(rooted.tasks.map(\.id)) == Set([prerequisite.id, dependent.id]))
    let independent = try await store.loadVisualTaskWorkspace(rootTaskID: standalone.id)
    #expect(independent.tasks.map(\.id) == [standalone.id])
  }

  @Test func workspaceInventoryIsBoundedAndReportsMoreIndependentTasks() async throws {
    let (core, store) = try fixture()
    for index in 0..<501 {
      _ = try await core.createTask(TaskCreateDraft(title: "Task \(index)"))
    }
    let page = try await core.listTasks(
      status: "all", listID: nil, priority: nil, text: nil, limit: 500, offset: 0)
    let snapshot = try await store.loadVisualTaskWorkspace()
    #expect(snapshot.tasks.map(\.id) == page.tasks.map(\.id))
    #expect(snapshot.tasks.count == 500)
    #expect(snapshot.warnings.contains(MobileTaskWorkspaceCopy.truncated))
  }

  @Test(.timeLimit(.minutes(1)))
  func workspaceCommitsBeforeSlowPublicationsAndCoalescesLatestState() async throws {
    let core = try SwiftLorvexCoreService.inMemory()
    let publisher = WorkspacePublicationGate()
    defer { publisher.gate.release() }
    let probes = WorkspacePublicationProbes()
    let store = MobileStore(
      core: core, taskReminderScheduler: probes, habitReminderScheduler: probes,
      widgetSnapshotPublisher: publisher,
      setBadge: { value in await probes.recordBadge(value) },
      notificationAuthorizationStatusProvider: {
        await probes.recordReminderAuthorization()
        return .authorized
      },
      defaults: UserDefaults(suiteName: "visual-publication-" + UUID().uuidString)!)
    let today = try #require(try await core.loadToday().logicalDay)
    let day = try #require(LorvexDateFormatters.ymdUTC.date(from: today))
    let first = try await core.createTask(TaskCreateDraft(title: "Prepare", plannedDate: day))
    let second = try await core.createTask(TaskCreateDraft(title: "Deliver", plannedDate: day))
    publisher.gate.holdNextPublication()
    var visualReturned = false
    let visual = Task {
      try await store.performVisualTaskAction(.addDependency(
        prerequisiteID: first.id, dependentID: second.id))
      visualReturned = true
    }
    #expect(await publicationSettled { publisher.gate.isHolding })
    let returnedBeforePublication = await publicationSettled { visualReturned }
    #expect(returnedBeforePublication)
    if !returnedBeforePublication {
      publisher.gate.release()
      try await visual.value
      return
    }
    #expect(try await core.loadTask(id: second.id).dependsOn == [first.id])
    #expect(!store.taskIsMutating(second.id))
    // A subsequent real edit commits while the first system publication is held.
    try await store.performVisualTaskAction(.removeDependency(
      prerequisiteID: first.id, dependentID: second.id))
    #expect(try await core.loadTask(id: second.id).dependsOn.isEmpty)
    #expect(await publicationSettled { store.taskSurfacesFlight.isPendingRerun })
    publisher.gate.release()
    try await visual.value
    #expect(await publicationSettled { !store.taskSurfacesFlight.isRunning })
    #expect(!store.taskSurfacesFlight.isPendingRerun)
    #expect(publisher.sources.count == 2)
    let latest = try #require(publisher.sources.last?.today.tasks.first { $0.id == second.id })
    #expect(latest.dependsOn.isEmpty)
    let afterVisual = await probes.counts()
    #expect(afterVisual.tasks == 2)
    #expect(afterVisual.habits == 2)
    #expect(afterVisual.badges == 2)
    // Completed setup deliberately skips the onboarding-only permission read;
    // the scheduler replacements above measure the actual reminder tail.
    #expect(afterVisual.authorizations == 0)

    // The normal API still awaits the complete publication tail.
    publisher.gate.holdNextPublication()
    var ordinaryReturned = false
    let ordinary = Task {
      let result = await store.completeTask(first.id)
      ordinaryReturned = true
      return result
    }
    #expect(await publicationSettled { publisher.gate.isHolding })
    #expect(!ordinaryReturned)
    #expect(try await core.loadTask(id: first.id).status == .completed)
    publisher.gate.release()
    #expect(await ordinary.value)
    let afterOrdinary = await probes.counts()
    #expect(afterOrdinary.tasks == 3)
    #expect(afterOrdinary.habits == 3)
    #expect(afterOrdinary.badges == 3)
    #expect(afterOrdinary.authorizations == 0)
    #expect(!store.taskSurfacesFlight.isRunning)
  }

  private func publicationSettled(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test func workspaceEditsSurviveStoreReopenAndPreserveIndependentDates() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "lorvex-visual-persistence-" + UUID().uuidString + ".sqlite")
    let core = SwiftLorvexCoreService(databasePath: path.path, writeInitiatorDefault: "user")
    let store = MobileStore(
      core: core, defaults: UserDefaults(suiteName: "visual-persistence-" + UUID().uuidString)!)
    let planned = try #require(LorvexDateFormatters.ymdUTC.date(from: "2026-12-02"))
    let due = try #require(LorvexDateFormatters.ymdUTC.date(from: "2026-12-08"))
    let task = try await core.createTask(TaskCreateDraft(
      title: "Persisted visual task", notes: "Preserve notes", plannedDate: planned))
    try await store.performVisualTaskAction(.setDueDate(
      taskID: task.id, date: PlannedDayBridge.displayDate(forStorageDate: due)))
    try await store.performVisualTaskAction(.setCompleted(taskID: task.id, completed: true))

    let reopened = SwiftLorvexCoreService(databasePath: path.path, writeInitiatorDefault: "user")
    let saved = try await reopened.loadTask(id: task.id)
    #expect(saved.id == task.id)
    #expect(saved.status == .completed)
    #expect(saved.notes == "Preserve notes")
    #expect(saved.dueDate == due)
    #expect(saved.plannedDate == planned)
    let reopenedStore = MobileStore(
      core: reopened, defaults: UserDefaults(suiteName: "visual-reopen-" + UUID().uuidString)!)
    let snapshot = try await reopenedStore.loadVisualTaskWorkspace()
    #expect(snapshot.tasks.first { $0.id == task.id }?.isCompleted == true)
    try await reopenedStore.performVisualTaskAction(.setPlannedDate(taskID: task.id, date: nil))
    let changed = try await reopened.loadTask(id: task.id)
    #expect(changed.plannedDate == nil)
    #expect(changed.dueDate == due)
  }
}

@MainActor
private final class WorkspacePublicationGate: MobileWidgetSnapshotPublishing {
  let gate = GatedMobileWidgetSnapshotPublisher()
  private(set) var sources: [WidgetSnapshotSource] = []

  func publish(source: WidgetSnapshotSource) async throws -> WidgetSnapshot {
    let snapshot = try await gate.publish(source: source)
    sources.append(source)
    return snapshot
  }
}

private actor WorkspacePublicationProbes: TaskReminderScheduling, HabitReminderScheduling {
  private var taskReminderPasses = 0
  private var habitReminderPasses = 0
  private var reminderAuthorizations = 0
  private var badges: [Int] = []

  func scheduleReminders(_ reminders: [ScheduledTaskReminder]) async -> TaskReminderScheduleReport {
    taskReminderPasses += 1
    return .scheduled(reminders.count)
  }

  func replaceScheduledHabitReminders(
    for occurrences: [DueHabitReminderOccurrence]
  ) async -> TaskReminderScheduleReport {
    habitReminderPasses += 1
    return .scheduled(occurrences.count)
  }

  func recordReminderAuthorization() { reminderAuthorizations += 1 }
  func recordBadge(_ value: Int) { badges.append(value) }
  func counts() -> (tasks: Int, habits: Int, badges: Int, authorizations: Int) {
    (taskReminderPasses, habitReminderPasses, badges.count, reminderAuthorizations)
  }
}
