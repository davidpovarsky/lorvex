import Foundation
import LorvexCore
import HanlinAgentCore
import HanlinHostContracts
import HanlinPlatformContracts

public struct LorvexHanlinWriteRequest: Sendable {
  public let tool: String
  public let objectIDs: [String]
  public let description: String
  public init(tool: String, objectIDs: [String], description: String) {
    self.tool = tool; self.objectIDs = objectIDs; self.description = description
  }
}

public struct LorvexHanlinArgs: Decodable, Sendable {
  public var id: String?
  public var query: String?
  public var status: String?
  public var text: String?
  public var listId: String?
  public var title: String?
  public var name: String?
  public var description: String?
  public var notes: String?
  public var priority: Int?
  public var limit: Int?
  public var offset: Int?
  public var dueDate: String?
  public var plannedDate: String?
  public var clearDue: Bool?
  public var clearPlanned: Bool?
  public var estimatedMinutes: Int?
  public var tags: [String]?
  public var date: String?
  public var from: String?
  public var to: String?
  public var startDate: String?
  public var endDate: String?
  public var startTime: String?
  public var endTime: String?
  public var allDay: Bool?
  public var location: String?
}

/// Routes Hanlin's existing SDK tool loop through Lorvex's *original* core.
/// Never creates a parallel SQLite service, changes schema, or copies MCP logic.
/// Consent must come from the live user UI immediately before every write.
public actor LorvexHanlinHost: HanlinHostIntegration {
  public typealias WriteAuthorizer = @Sendable (LorvexHanlinWriteRequest) async -> Bool
  public nonisolated let apiVersion = HanlinAPIVersion(major: 1, minor: 1)
  private let core: any LorvexCoreServicing
  private let authorizer: WriteAuthorizer
  private let didWrite: @Sendable () async -> Void
  private var contextValue: HanlinHostContext
  private var cancelled = Set<String>()
  private var receipts: [String: HanlinHostExecutionResult] = [:]

  public init(
    core: any LorvexCoreServicing, context: HanlinHostContext,
    authorizeWrite: @escaping WriteAuthorizer = { _ in false },
    didWrite: @escaping @Sendable () async -> Void = {}
  ) {
    self.core = core
    self.contextValue = context
    self.authorizer = authorizeWrite
    self.didWrite = didWrite
  }

  public func setContext(_ context: HanlinHostContext) {
    contextValue = context
    receipts.removeAll()
  }

  public func context(for session: HanlinHostSession) throws -> HanlinHostContext {
    guard contextValue.namespace == session.context.namespace else { throw HanlinHostError.staleContext }
    return contextValue
  }

  public func catalog(for context: HanlinHostContext) throws -> HanlinHostCatalog {
    guard contextValue == context else { throw HanlinHostError.staleContext }
    return try LorvexHanlinToolCatalog.catalog(for: context)
  }

  public func cancel(_ invocation: HanlinToolInvocationID) {
    cancelled.insert(invocation.rawValue)
  }

  public func open(_ destination: HanlinHostDestination) throws -> HanlinHostNavigationResult {
    guard contextValue == destination.context else { throw HanlinHostError.staleContext }
    return .queued(requestID: destination.requestID, context: contextValue)
  }

  public func execute(
    _ invocation: HanlinHostInvocation,
    progress: @escaping HanlinHostProgressHandler
  ) async throws -> HanlinHostExecutionResult {
    let request = invocation.request
    if let old = receipts[request.id.rawValue] { return old }
    guard !cancelled.contains(request.id.rawValue),
          invocation.session.context == contextValue,
          request.routingTableRevision == .init(1),
          invocation.expectedRevision == nil,
          let spec = LorvexHanlinToolCatalog.specs.first(where: { $0.alias == request.aliasUsed }),
          let schema = try? spec.schemaJSON()
    else { return failed(invocation, effect: .notDispatched) }

    let original: Data
    if let accepted = invocation.originalArgumentsJSON {
      original = accepted
    } else {
      original = try request.arguments.canonicalJSONData()
    }
    do {
      try HanlinHostSchemaValidation(schemaJSON: schema).validate(argumentsJSON: original)
    } catch {
      return failed(invocation, effect: .notDispatched)
    }
    let args: LorvexHanlinArgs
    do {
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      args = try decoder.decode(LorvexHanlinArgs.self, from: original)
    } catch {
      return failed(invocation, effect: .notDispatched)
    }

    if spec.writes {
      let approval = LorvexHanlinWriteRequest(
        tool: spec.alias,
        objectIDs: args.id.map { [$0] } ?? [],
        description: "\(spec.summary): \(args.title ?? args.name ?? args.id ?? "current selection")")
      let authorized = await authorizer(approval)
      guard authorized, !cancelled.contains(request.id.rawValue),
            contextValue == invocation.session.context,
            !_Concurrency.Task<Never, Never>.isCancelled else {
        return failed(invocation, effect: .notDispatched)
      }
    }

    do {
      try _Concurrency.Task<Never, Never>.checkCancellation()
      guard !cancelled.contains(request.id.rawValue),
            contextValue == invocation.session.context else { throw HanlinHostError.staleContext }
      let json = try await perform(spec.alias, args)
      let receipt = HanlinHostExecutionResult(
        result: .init(invocationID: request.id, logicalToolID: request.logicalToolID,
                      outcome: .completed([.text(json)]), completedAt: .now),
        effectState: spec.writes ? .confirmedCommitted : .confirmedNoEffect,
        context: invocation.session.context,
        reconciliationReference: spec.writes ? request.id.rawValue : nil)
      receipts[request.id.rawValue] = receipt
      if spec.writes { await didWrite() }
      return receipt
    } catch {
      // A mutation can have committed before cancellation or transport failure.
      // Never retry an uncertain write without reconciling in the original context.
      let receipt = failed(invocation,
        effect: spec.writes ? .uncertain : .confirmedNoEffect)
      receipts[request.id.rawValue] = receipt
      return receipt
    }
  }

  private func failed(
    _ invocation: HanlinHostInvocation, effect: HanlinHostEffectState
  ) -> HanlinHostExecutionResult {
    HanlinHostExecutionResult(
      result: .init(
        invocationID: invocation.request.id, logicalToolID: invocation.request.logicalToolID,
        outcome: .failed(.init(
          code: effect == .notDispatched ? .permissionDenied : .nativeFailure,
          userMessage: effect == .uncertain
            ? "Write outcome uncertain. Re-read the original task before retry."
            : "Action was invalid, unavailable or not approved")),
        completedAt: .now),
      effectState: effect, context: invocation.session.context,
      reconciliationReference: effect == .uncertain ? invocation.request.id.rawValue : nil)
  }

  private func perform(_ tool: String, _ a: LorvexHanlinArgs) async throws -> String {
    switch tool {
    case "list_tasks":
      let page = try await core.listTasks(
        status: a.status ?? "all", listID: a.listId, priority: a.priority,
        text: a.text, limit: a.limit ?? 100, offset: a.offset ?? 0)
      return try Self.encode([
        "tasks": page.tasks.map(Self.taskData),
        "totalMatching": page.totalMatching, "truncated": page.truncated,
        "nextOffset": page.nextOffset as Any? ?? NSNull()
      ])
    case "get_task":
      guard let id = a.id else { throw HanlinHostError.invalidArguments }
      return try Self.encode(["task": Self.taskData(try await core.loadTask(id: id))])
    case "search_tasks":
      guard let query = a.query else { throw HanlinHostError.invalidArguments }
      let page = try await core.searchTasks(query: query, status: a.status ?? "all",
                                             limit: a.limit ?? 100, offset: 0)
      return try Self.encode(["tasks": page.tasks.map(Self.taskData),
                              "totalMatching": page.totalMatching, "truncated": page.truncated])
    case "get_summary":
      let page = try await core.listTasks(
        status: "all", listID: nil, priority: nil,
        text: nil, limit: 200, offset: 0)
      let tasks = page.tasks
      let byPriority = Dictionary(grouping: tasks, by: { $0.priority.tier }).mapValues(\.count)
      let byStatus = Dictionary(grouping: tasks, by: { $0.status.rawValue }).mapValues(\.count)
      return try Self.encode([
        "totalMatching": page.totalMatching, "sampleSize": tasks.count,
        "partial": page.truncated, "byPriority": byPriority, "byStatus": byStatus,
        "open": tasks.filter { $0.isActionable }.count,
        "completed": tasks.filter { $0.status == .completed }.count
      ])
    case "get_today":
      let today = try await core.loadToday()
      return try Self.encode(["summary": today.summary, "briefing": today.briefing as Any? ?? NSNull(),
                              "logicalDay": today.logicalDay as Any? ?? NSNull(),
                              "tasks": today.tasks.map(Self.taskData)])
    case "list_lists":
      let catalog = try await core.loadLists()
      return try Self.encode(["lists": catalog.lists.map(Self.listData)])
    case "get_list_detail":
      guard let id = a.id else { throw HanlinHostError.invalidArguments }
      let page = try await core.loadListDetail(id: id, limit: a.limit ?? 100, offset: 0)
      return try Self.encode(["list": Self.listData(page.list),
                              "tasks": page.tasks.map(Self.taskData),
                              "totalMatching": page.totalMatching, "truncated": page.truncated])
    case "list_events":
      guard let from = a.from, let to = a.to else { throw HanlinHostError.invalidArguments }
      _ = try Self.parseDay(from); _ = try Self.parseDay(to)
      guard from <= to else { throw HanlinHostError.invalidArguments }
      let calendar = try await core.loadCalendarTimeline(from: from, to: to)
      return try Self.encode(["events": calendar.events.map(Self.eventData),
                              "truncated": calendar.truncated])
    case "get_event":
      guard let id = a.id, let event = try await core.getCalendarEvent(id: id)
      else { throw HanlinHostError.invalidArguments }
      return try Self.encode(["event": Self.eventData(event)])
    case "list_habits":
      let date = a.date ?? Self.dayString(Date())
      _ = try Self.parseDay(date)
      let catalog = try await core.loadHabits(date: date)
      return try Self.encode(["date": date, "habits": catalog.habits.map(Self.habitData)])
    case "create_task":
      guard let title = a.title else { throw HanlinHostError.invalidArguments }
      let task = try await core.createTask(.init(
        title: title, notes: a.notes ?? "", listID: a.listId,
        priority: a.priority.flatMap(LorvexTask.Priority.init(tier:)) ?? .p2,
        estimatedMinutes: a.estimatedMinutes,
        dueDate: try Self.optionalDate(a.dueDate),
        plannedDate: try Self.optionalDate(a.plannedDate),
        tags: a.tags))
      return try Self.encode(["task": Self.taskData(task)])
    case "update_task":
      guard let id = a.id else { throw HanlinHostError.invalidArguments }
      var draft = TaskUpdateDraft(
        id: id, title: a.title, notes: a.notes,
        priority: a.priority.flatMap(LorvexTask.Priority.init(tier:)), tags: a.tags)
      if a.clearDue == true { draft.dueDate = .clear }
      else if let due = a.dueDate { draft.dueDate = .set(try Self.parseDay(due)) }
      if a.clearPlanned == true { draft.plannedDate = .clear }
      else if let planned = a.plannedDate {
        draft.plannedDate = .set(try Self.parseDay(planned))
      }
      if let estimate = a.estimatedMinutes { draft.estimatedMinutes = .set(estimate) }
      let task = try await core.updateTask(draft)
      return try Self.encode(["task": Self.taskData(task)])
    case "complete_task", "reopen_task", "start_task", "pause_task", "cancel_task":
      guard let id = a.id else { throw HanlinHostError.invalidArguments }
      switch tool {
      case "complete_task": _ = try await core.completeTask(id: id)
      case "reopen_task": _ = try await core.reopenTask(id: id)
      case "start_task": _ = try await core.startTask(id: id)
      case "pause_task": _ = try await core.pauseTask(id: id)
      default: _ = try await core.cancelTask(id: id)
      }
      return try Self.encode(["task": Self.taskData(try await core.loadTask(id: id))])
    case "plan_task":
      guard let id = a.id, let date = a.date else { throw HanlinHostError.invalidArguments }
      let updated = try await core.updateTask(.init(
        id: id, plannedDate: .set(try Self.parseDay(date))))
      return try Self.encode(["task": Self.taskData(updated)])
    case "create_event":
      guard let title = a.title, let start = a.startDate else {
        throw HanlinHostError.invalidArguments
      }
      _ = try Self.parseDay(start)
      if let end = a.endDate { _ = try Self.parseDay(end) }
      let event = try await core.createCalendarEvent(
        title: title, startDate: start, endDate: a.endDate,
        startTime: a.startTime, endTime: a.endTime,
        allDay: a.allDay ?? false,
        location: a.location, notes: a.notes, recurrence: nil,
        timezone: nil, url: nil, color: nil, eventType: nil,
        personName: nil, attendees: nil)
      return try Self.encode(["event": Self.eventData(event)])
    case "create_list":
      guard let name = a.name else { throw HanlinHostError.invalidArguments }
      let list = try await core.createList(name: name, description: a.description)
      return try Self.encode(["list": Self.listData(list)])
    case "complete_habit", "uncomplete_habit":
      guard let id = a.id, let date = a.date else { throw HanlinHostError.invalidArguments }
      _ = try Self.parseDay(date)
      let catalog: HabitCatalogSnapshot
      if tool == "complete_habit" {
        catalog = try await core.completeHabit(id: id, date: date)
      } else {
        catalog = try await core.uncompleteHabit(id: id, date: date)
      }
      return try Self.encode(["habits": catalog.habits.map(Self.habitData)])
    default: throw HanlinHostError.unknownTool
    }
  }

  private static func optionalDate(_ value: String?) throws -> Date? {
    guard let value else { return nil }
    return try parseDay(value)
  }
  private static func parseDay(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard value.utf8.count == 10, let date = formatter.date(from: value),
          formatter.string(from: date) == value else { throw HanlinHostError.invalidArguments }
    return date
  }
  private static func dayString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.string(from: date)
  }
  private static func timestamp(_ date: Date?) -> Any {
    guard let date else { return NSNull() }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
  private static func taskData(_ task: LorvexTask) -> [String: Any] {
    [
      "id": task.id, "title": task.title, "notes": task.notes,
      "priority": task.priority.tier, "status": task.status.rawValue,
      "listId": task.listID as Any? ?? NSNull(),
      "dueDate": timestamp(task.dueDate),
      "plannedDate": timestamp(task.plannedDate),
      "estimatedMinutes": task.estimatedMinutes as Any? ?? NSNull(),
      "tags": task.tags, "dependsOn": task.dependsOn
    ]
  }
  private static func listData(_ list: LorvexList) -> [String: Any] {
    [
      "id": list.id, "name": list.name,
      "description": list.description as Any? ?? NSNull(),
      "openCount": list.openCount, "completedCount": list.completedCount,
      "totalCount": list.totalCount
    ]
  }
  private static func eventData(_ event: CalendarTimelineEvent) -> [String: Any] {
    [
      "id": event.id, "title": event.title, "startDate": event.startDate,
      "startTime": event.startTime as Any? ?? NSNull(),
      "endDate": event.endDate as Any? ?? NSNull(),
      "endTime": event.endTime as Any? ?? NSNull(),
      "allDay": event.allDay, "source": event.source,
      "location": event.location as Any? ?? NSNull()
    ]
  }
  private static func habitData(_ habit: LorvexHabit) -> [String: Any] {
    [
      "id": habit.id, "name": habit.name, "targetCount": habit.targetCount,
      "completionsToday": habit.completionsToday,
      "completionRate30d": habit.completionRate30d,
      "isSkipped": habit.isSkipped
    ]
  }
  private static func encode(_ value: [String: Any]) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else { throw HanlinHostError.invalidArguments }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard data.count < 1_048_576, let text = String(data: data, encoding: .utf8) else {
      throw HanlinHostError.outputLimitExceeded
    }
    return text
  }
}
