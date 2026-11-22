import Foundation
import Testing
import LorvexCore
import HanlinAgentCore
import HanlinHostContracts
import HanlinPlatformContracts
@testable import LorvexHanlinAgent

@MainActor
struct LorvexHanlinAgentTests {
  private func fixture() throws -> (
    any LorvexCoreServicing, HanlinHostContext, HanlinHostSession
  ) {
    let tmp = FileManager.default.temporaryDirectory
      .appending(path: "lorvex-hanlin-agent-" + UUID().uuidString + ".sqlite")
    let core = SwiftLorvexCoreService(databasePath: tmp.path)
    let namespace = try HanlinConversationNamespace(
      app: "lorvex", account: "test-account", workspace: "personal", space: "tasks")
    let context = HanlinHostContext(
      namespace: namespace, sceneID: UUID(), generation: UUID())
    return (core, context, .init(conversationID: UUID(), context: context))
  }

  @Test func catalogValidatesAndIncludes22ScopedTools() throws {
    let (_, context, _) = try fixture()
    let catalog = try LorvexHanlinToolCatalog.catalog(for: context)
    try catalog.validate()
    #expect(catalog.tools.count == 22)
    #expect(Set(catalog.tools.map(\.route.alias)).count == 22)
    #expect(catalog.tools.filter { $0.writeGuarantee != .readOnly }.count == 12)
    for spec in LorvexHanlinToolCatalog.specs {
      _ = try HanlinHostSchemaValidation(schemaJSON: spec.schemaJSON())
    }
  }

  @Test func readsAndDenyByDefaultCannotModifyTasks() async throws {
    let (core, context, session) = try fixture()
    let host = LorvexHanlinHost(core: core, context: context)
    let dispatcher = HanlinHostDispatcher(host: host)
    let catalog = try await host.catalog(for: context)
    let result = try await dispatcher.dispatch(
      alias: "list_tasks", argumentsJSON: #"{"limit":10}"#,
      providerCallID: "first-read", runID: UUID(), step: 0,
      session: session, catalog: catalog, limits: .init())
    #expect(result.effectState == .confirmedNoEffect)
    let denied = try await dispatcher.dispatch(
      alias: "create_task", argumentsJSON: #"{"title":"Do not add"}"#,
      providerCallID: "denied-create", runID: UUID(), step: 0,
      session: session, catalog: catalog, limits: .init())
    #expect(denied.effectState == .notDispatched)
    let page = try await core.listTasks(
      status: "all", listID: nil, priority: nil,
      text: nil, limit: 50, offset: 0)
    #expect(page.tasks.isEmpty)
  }

  @Test func approvedCreateAndIdempotentReplay() async throws {
    let (core, context, session) = try fixture()
    let host = LorvexHanlinHost(core: core, context: context, authorizeWrite: { _ in true })
    let dispatcher = HanlinHostDispatcher(host: host)
    let catalog = try await host.catalog(for: context)
    let runID = UUID()
    let first = try await dispatcher.dispatch(
      alias: "create_task", argumentsJSON: #"{"title":"Approved task","priority":1}"#,
      providerCallID: "create-1", runID: runID, step: 0,
      session: session, catalog: catalog, limits: .init())
    #expect(first.effectState == .confirmedCommitted)
    let replay = try await dispatcher.dispatch(
      alias: "create_task", argumentsJSON: #"{"title":"Approved task","priority":1}"#,
      providerCallID: "create-1", runID: runID, step: 0,
      session: session, catalog: catalog, limits: .init())
    #expect(replay.result == first.result)
    let page = try await core.listTasks(
      status: "all", listID: nil, priority: nil,
      text: nil, limit: 50, offset: 0)
    #expect(page.tasks.count == 1)
    let summary = try await dispatcher.dispatch(
      alias: "get_summary", argumentsJSON: "{}",
      providerCallID: "summary-after-create", runID: UUID(), step: 0,
      session: session, catalog: catalog, limits: .init())
    if case let .completed(parts) = summary.result.outcome,
       let first = parts.first, case let .text(text) = first,
       let bytes = text.data(using: .utf8) {
      let decoded = try JSONDecoder().decode(LorvexHanlinSummary.self, from: bytes)
      #expect(decoded.totalMatching == 1)
      #expect(decoded.byPriority["1"] == 1)
      #expect(decoded.buckets(by: "priority").count == 1)
    } else {
      Issue.record("Expected a machine-readable get_summary tool result")
    }
  }

  @Test func staleContextDoesNotWrite() async throws {
    let (core, context, session) = try fixture()
    let host = LorvexHanlinHost(core: core, context: context, authorizeWrite: { _ in true })
    let catalog = try await host.catalog(for: context)
    await host.setContext(.init(
      namespace: context.namespace, sceneID: context.sceneID, generation: UUID()))
    let dispatcher = HanlinHostDispatcher(host: host)
    var blocked = false
    do {
      _ = try await dispatcher.dispatch(
        alias: "create_task", argumentsJSON: #"{"title":"Stale"}"#,
        providerCallID: "stale-1", runID: UUID(), step: 0,
        session: session, catalog: catalog, limits: .init())
    } catch { blocked = true }
    #expect(blocked)
    let page = try await core.listTasks(
      status: "all", listID: nil, priority: nil,
      text: nil, limit: 50, offset: 0)
    #expect(page.tasks.isEmpty)
  }
}
