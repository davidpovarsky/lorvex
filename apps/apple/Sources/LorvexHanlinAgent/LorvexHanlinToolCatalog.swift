import Foundation
import HanlinHostContracts
import HanlinPlatformContracts

/// Native, explicit Lorvex tool catalog for the existing HanlinAgentSDK.
/// All writes are subject to an additional user approval at the host boundary.
public enum LorvexHanlinToolCatalog {
  public enum Field: Sendable {
    case text(Int)
    case optionalText(Int)
    case flag
    case integer(Int, Int)
    case choices([String])
    case texts(Int, Int)

    func jsonSchema() -> [String: Any] {
      switch self {
      case .text(let max): return ["type": "string", "minLength": 1, "maxLength": max]
      case .optionalText(let max): return ["type": "string", "maxLength": max]
      case .flag: return ["type": "boolean"]
      case .integer(let min, let max):
        return ["type": "integer", "minimum": min, "maximum": max]
      case .choices(let allowed): return ["type": "string", "enum": allowed]
      case .texts(let maxItems, let maxLength):
        return ["type": "array", "maxItems": maxItems,
                "items": ["type": "string", "minLength": 1, "maxLength": maxLength]]
      }
    }
  }

  public struct Spec: Sendable {
    public let alias: String
    public let summary: String
    public let writes: Bool
    public let fields: [String: Field]
    public let required: [String]
    init(_ alias: String, _ summary: String, writes: Bool = false,
         fields: [String: Field] = [:], required: [String] = []) {
      self.alias = alias; self.summary = summary; self.writes = writes
      self.fields = fields; self.required = required
    }
    public func schemaJSON() throws -> Data {
      try JSONSerialization.data(
        withJSONObject: ["type": "object",
                         "properties": fields.mapValues { $0.jsonSchema() },
                         "required": required,
                         "additionalProperties": false],
        options: [.sortedKeys])
    }
  }

  public static let specs: [Spec] = [
    .init("list_tasks", "List tasks with optional filters and pagination",
          fields: ["status": .choices(["all","open","actionable","completed","cancelled","someday"]),
                   "list_id": .text(128), "priority": .integer(1,3),
                   "text": .optionalText(250), "limit": .integer(1,200),
                   "offset": .integer(0,50000)]),
    .init("get_task", "Read one task by its exact ID", fields: ["id": .text(128)], required: ["id"]),
    .init("search_tasks", "Full-text search for tasks", fields: [
      "query": .text(250), "status": .choices(["all","open","completed","cancelled","someday"]),
      "limit": .integer(1,200)], required: ["query"]),
    .init("get_summary", "Task completion and priority statistics for a dashboard"),
    .init("get_today", "Today's actionable task briefing and schedule"),
    .init("list_lists", "Browse lists and their workload statistics"),
    .init("get_list_detail", "Get one list with its task page",
          fields: ["id": .text(128), "limit": .integer(1,200)], required: ["id"]),
    .init("list_events", "Read calendar events for an inclusive YYYY-MM-DD window",
          fields: ["from": .text(10), "to": .text(10)], required: ["from","to"]),
    .init("get_event", "Read one Lorvex-owned calendar event",
          fields: ["id": .text(128)], required: ["id"]),
    .init("list_habits", "Get habit progress for a specific YYYY-MM-DD",
          fields: ["date": .text(10)], required: ["date"]),
    .init("create_task", "Create a Lorvex task through the canonical core service",
          writes: true, fields: [
            "title": .text(500), "notes": .optionalText(8000), "priority": .integer(1,3),
            "list_id": .text(128), "due_date": .text(35), "planned_date": .text(35),
            "estimated_minutes": .integer(1,10080), "tags": .texts(50,80)],
          required: ["title"]),
    .init("update_task", "Safely patch only the specified task fields", writes: true,
          fields: ["id": .text(128), "title": .text(500), "notes": .optionalText(8000),
                   "priority": .integer(1,3), "due_date": .text(35), "planned_date": .text(35),
                   "clear_due": .flag, "clear_planned": .flag,
                   "estimated_minutes": .integer(1,10080), "tags": .texts(50,80)],
          required: ["id"]),
    .init("complete_task", "Mark an active task complete", writes: true,
          fields: ["id": .text(128)], required: ["id"]),
    .init("reopen_task", "Reopen a completed or cancelled task", writes: true,
          fields: ["id": .text(128)], required: ["id"]),
    .init("start_task", "Start work on a task", writes: true,
          fields: ["id": .text(128)], required: ["id"]),
    .init("pause_task", "Pause work on an in-progress task", writes: true,
          fields: ["id": .text(128)], required: ["id"]),
    .init("cancel_task", "Cancel a task through Lorvex's canonical lifecycle", writes: true,
          fields: ["id": .text(128)], required: ["id"]),
    .init("plan_task", "Plan a task for a specific YYYY-MM-DD", writes: true,
          fields: ["id": .text(128), "date": .text(10)], required: ["id","date"]),
    .init("create_event", "Create a Lorvex calendar event", writes: true,
          fields: ["title": .text(500), "start_date": .text(10), "end_date": .text(10),
                   "start_time": .text(8), "end_time": .text(8), "all_day": .flag,
                   "location": .optionalText(500), "notes": .optionalText(8000)],
          required: ["title","start_date"]),
    .init("create_list", "Create a new named Lorvex task list", writes: true,
          fields: ["name": .text(150), "description": .optionalText(3000)], required: ["name"]),
    .init("complete_habit", "Record a habit completion on YYYY-MM-DD", writes: true,
          fields: ["id": .text(128), "date": .text(10)], required: ["id","date"]),
    .init("uncomplete_habit", "Clear a habit check-in on YYYY-MM-DD", writes: true,
          fields: ["id": .text(128), "date": .text(10)], required: ["id","date"])
  ]

  public static func catalog(for context: HanlinHostContext) throws -> HanlinHostCatalog {
    let tools: [HanlinHostTool] = try specs.map { spec in
      let logical = HanlinLogicalToolID(
        providerInstanceID: try .init(validating: "lorvex.hanlin"),
        localToolID: try .init(validating: spec.alias))
      let revision = try HanlinDescriptorRevision(1)
      let bytes = try spec.schemaJSON()
      let document = try HanlinJSONSchemaDocument.decodeCanonicalJSON(
        bytes, defaultDialect: .draft2020_12)
      let descriptor = HanlinToolDescriptor(
        logicalID: logical, descriptorRevision: revision, owner: .system,
        title: try .init(["en": spec.alias]),
        summary: try .init(["en": spec.summary]),
        inputSchema: document, risk: spec.writes ? .write : .read, presentation: .init())
      return HanlinHostTool(
        route: .init(alias: spec.alias, logicalToolID: logical, descriptorRevision: revision),
        descriptor: descriptor,
        writeGuarantee: spec.writes ? .hostManagedMutation : .readOnly,
        originalInputSchemaJSON: bytes)
    }
    let result = HanlinHostCatalog(
      apiVersion: .init(major: 1, minor: 1),
      revision: .init(1), context: context, tools: tools)
    try result.validate()
    return result
  }
}
