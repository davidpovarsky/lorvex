import Foundation
import Synchronization
import Testing
import LorvexCore
import HanlinAgentCore
import HanlinChatCore
import HanlinHostContracts
import HanlinPlatformContracts
@testable import LorvexHanlinAgent

@MainActor
struct LorvexHanlinConversationPersistenceTests {
  @Test func reopeningPreservesRolesDraftRichDisplayAndNeverExecutesSavedTools() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scope = scope()
    let first = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory)
    await first.selectConversation(scope)
    let turn = try #require(first.beginResponse(prompt: "זכור את התוכנית שלי"))
    first.consume(.textDelta("התוכנית נשמרה"), runID: turn.runID, responseID: turn.responseID)
    first.consume(.reasoningDelta("Read the original task core."), runID: turn.runID, responseID: turn.responseID)
    first.consume(.toolCall(.init(id: "saved-create", name: "create_task",
      argumentsJSON: #"{"title":"Do not replay this saved call"}"#)),
      runID: turn.runID, responseID: turn.responseID)
    first.consume(.toolResult(callID: "saved-create", name: "create_task", modelText: #"{"id":"past-task"}"#,
      resultReference: nil, isError: false), runID: turn.runID, responseID: turn.responseID)
    first.consume(.toolResult(callID: "saved-workspace", name: "show_task_workspace",
      modelText: #"{"presentation":"matrix","rootTaskID":"past-task"}"#,
      resultReference: nil, isError: false), runID: turn.runID, responseID: turn.responseID)
    first.consume(.source(id: "source", url: "https://example.test/plan", title: "Plan"),
      runID: turn.runID, responseID: turn.responseID)
    let structured = try HanlinChatStructuredPart(messageID: UUID(), partID: UUID(), sequence: 0,
      payload: .a2uiMessage(protocolVersion: "0.8",
        json: Data(#"{"surfaceUpdate":{"surfaceId":"saved","components":[]}}"#.utf8)))
    first.consume(.structuredPart(structured), runID: turn.runID, responseID: turn.responseID)
    first.finishResponse(runID: turn.runID, responseID: turn.responseID)
    first.setReasoningExpanded(true, messageID: turn.responseID)
    first.setActivityExpanded(true, messageID: turn.responseID, activityID: "saved-create")
    first.updateDraft("טיוטה לפעם הבאה", scope: scope)
    try await first.flushConversation()
    let expected = first.messages

    let reopened = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory)
    await reopened.selectConversation(scope)
    #expect(reopened.messages == expected)
    #expect(reopened.messages.map(\.role) == [.user, .assistant])
    #expect(reopened.draft == "טיוטה לפעם הבאה")
    #expect(reopened.messages.last?.structuredParts == [structured])
    #expect(reopened.messages.last?.reasoningExpanded == true)
    #expect(reopened.messages.last?.expandedActivityIDs == ["saved-create"])
    #expect(reopened.messages.last?.workspaces.first?.presentation == "matrix")
    #expect(!reopened.isRunning)
    #expect(reopened.pendingApproval == nil && reopened.pendingApprovalID == nil)
    let tasks = try await fixture.core.listTasks(
      status: "all", listID: nil, priority: nil, text: nil, limit: 10, offset: 0)
    #expect(tasks.tasks.isEmpty, "Saved create_task activity must never dispatch while restoring")
  }

  @Test func cloudProviderAndAccountScopesStayIsolatedWithoutReassigningLegacyJournal() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = scope()
    let history = try LorvexHanlinConversationHistoryRegistry.history(scope: original, directory: fixture.directory)
    let owner = UUID()
    _ = try await history.activate(owner: owner)
    let expected = LorvexHanlinConversationSnapshot(
      messages: [.init(role: .user, text: "Account A only")], draft: "A draft")
    try await history.save(expected, owner: owner).value
    let store = try LorvexHanlinConversationHistoryRegistry.store(directory: fixture.directory)
    let legacyNamespace = try HanlinConversationNamespace(
      app: "lorvex", account: "device-local", workspace: "personal", space: "tasks")
    let legacyID = UUID()
    let legacy = HanlinConversationRecord(namespace: legacyNamespace, conversationID: legacyID, revision: 0,
      entries: [.init(runID: UUID(), step: 0, sequence: 0, payload: .text("Legacy unknown owner"))])
    try await store.save(legacy, replacing: nil)

    let alternatives = [
      scope(cloud: "cloud-b"), scope(provider: "ChatGPT"),
      scope(account: "profile-b"), scope(endpoint: "https://other.invalid/v1"),
      scope(cloud: nil), scope(account: nil)
    ]
    let state = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory)
    for alternative in alternatives {
      await state.selectConversation(alternative)
      #expect(state.isConversationReady)
      #expect(state.messages.isEmpty && state.draft.isEmpty)
    }
    await state.selectConversation(original)
    #expect(state.messages == expected.messages && state.draft == expected.draft)
    let preserved = try await store.load(legacyID, namespace: legacyNamespace)
    #expect(preserved == legacy)
    #expect(try original.displayNamespace != legacyNamespace)
  }

  @Test func namespaceEncodingIsUnambiguousAndChatGPTRefreshDoesNotChangeHistoryIdentity() {
    let a = scope(cloud: "a", provider: "bc", account: "registration")
    let b = scope(cloud: "ab", provider: "c", account: "registration")
    #expect(a != b)
    #expect(scope(cloud: nil) != scope(cloud: ""))
    #expect(scope(account: nil) != scope(account: ""))
    let before = scope(provider: "ChatGPT", account: "validated-client-id")
    let after = scope(provider: "ChatGPT", account: "validated-client-id")
    #expect(before == after)
    #expect(!before.accountID.contains("validated-client-id"))
    let oldEngine = LorvexHanlinAssistantState.ModelIdentity(provider: "ChatGPT",
      endpoint: before.endpoint, modelID: "model", credential: "old-access-token")
    let newEngine = LorvexHanlinAssistantState.ModelIdentity(provider: "ChatGPT",
      endpoint: after.endpoint, modelID: "model", credential: "refreshed-access-token")
    #expect(oldEngine != newEngine, "Refresh replaces the live engine without changing the history scope")
  }

  @Test func newOwnerWaitsForAdmittedSaveAndRejectsLateOldWrites() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let history = try LorvexHanlinConversationHistoryRegistry.history(scope: scope(), directory: fixture.directory)
    let old = UUID()
    _ = try await history.activate(owner: old)
    let before = LorvexHanlinConversationSnapshot(messages: [.init(role: .user, text: "Before reopen")])
    let queued = history.save(before, owner: old)
    let current = UUID()
    let restored = try await history.activate(owner: current)
    try await queued.value
    #expect(restored == before)
    let expected = LorvexHanlinConversationSnapshot(messages: [.init(role: .assistant, text: "Current")])
    try await history.save(expected, owner: current).value
    do {
      try await history.save(.init(messages: [.init(role: .assistant, text: "Late old answer")]), owner: old).value
      Issue.record("A retired owner overwrote the current record")
    } catch is CancellationError { }
    let final = try await history.activate(owner: UUID())
    #expect(final == expected)
  }

  @Test func unknownDisplayVersionAndRoleRemainUnchangedAndCannotReachProvider() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = try LorvexHanlinConversationHistoryRegistry.store(directory: fixture.directory)
    let valid = LorvexHanlinConversationSnapshot(messages: [.init(role: .user, text: "Keep these bytes")])
    for variant in ["future-version", "unknown-role"] {
      let scope = scope(account: variant)
      let validBytes = try JSONEncoder().encode(valid)
      var object = try #require(try JSONSerialization.jsonObject(
        with: validBytes) as? [String: Any])
      if variant == "future-version" { object["version"] = 99 }
      else {
        var rows = try #require(object["messages"] as? [[String: Any]])
        rows[0]["role"] = "future-authority"
        object["messages"] = rows
      }
      let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      let record = try record(scope: scope, revision: 0, text: String(decoding: bytes, as: UTF8.self))
      try await store.save(record, replacing: nil)
      let calls = Mutex(0)
      let state = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory) {
        _, _, _, _, _ in
        calls.withLock { $0 += 1 }
        throw URLError(.cancelled)
      }
      await state.selectConversation(scope)
      #expect(!state.isConversationReady)
      #expect(state.errorMessage != nil)
      await state.send("Do not overwrite", modelID: "fixture", endpoint: scope.endpoint,
        credential: "fixture-key", provider: scope.provider, scope: scope)
      #expect(calls.withLock { $0 } == 0)
      #expect(state.messages.isEmpty)
      let after = try await store.load(scope.conversationID, namespace: scope.displayNamespace)
      #expect(after == record)
    }
  }

  @Test func unreadableStoreCannotBeReplacedByAnEmptyConversation() async throws {
    let scope = scope()
    let original = try record(scope: scope, revision: 7, snapshot: .init(messages: [.init(role: .user, text: "Keep")]))
    let store = HistoryMemoryStore(value: original, readFails: true)
    let history = LorvexHanlinConversationHistory(
      scope: scope, store: store, directory: URL(fileURLWithPath: "/unused-history-fixture"))
    let owner = UUID()
    do {
      _ = try await history.activate(owner: owner)
      Issue.record("Unreadable storage unexpectedly loaded")
    } catch { }
    do {
      try await history.save(.init(messages: []), owner: owner).value
      Issue.record("Unreadable storage unexpectedly saved")
    } catch { }
    let (value, writes) = await store.snapshot()
    #expect(value == original && writes == 0)
  }

  @Test func maximumRevisionIsRejectedWithoutOverflowOrReplacement() async throws {
    let scope = scope()
    let original = try record(scope: scope, revision: UInt64.max,
      snapshot: .init(messages: [.init(role: .user, text: "Last valid revision")]))
    let store = HistoryMemoryStore(value: original)
    let history = LorvexHanlinConversationHistory(
      scope: scope, store: store, directory: URL(fileURLWithPath: "/unused-history-fixture"))
    let owner = UUID()
    _ = try await history.activate(owner: owner)
    do {
      try await history.save(.init(messages: [.init(role: .user, text: "Must not replace")]), owner: owner).value
      Issue.record("UInt64.max was incremented")
    } catch HanlinHostError.storageLimitExceeded { }
    let (value, writes) = await store.snapshot()
    #expect(value == original && writes == 0)
  }

  @Test func compareAndSwapConflictNeverOverwritesOrRetriesAnotherRevision() async throws {
    let scope = scope()
    let original = try record(scope: scope, revision: 0,
      snapshot: .init(messages: [.init(role: .user, text: "Before")]))
    let concurrentSnapshot = LorvexHanlinConversationSnapshot(
      messages: [.init(role: .user, text: "Concurrent owner")])
    let concurrent = try record(scope: scope, revision: 1, snapshot: concurrentSnapshot)
    for phase in ["before-save-load", "during-cas"] {
      let store = HistoryMemoryStore(value: original,
        conflictingReplacement: phase == "during-cas" ? concurrent : nil)
      let history = LorvexHanlinConversationHistory(
        scope: scope, store: store, directory: URL(fileURLWithPath: "/unused-history-fixture"))
      let owner = UUID()
      _ = try await history.activate(owner: owner)
      if phase == "before-save-load" { await store.replaceFromExternalWriter(concurrent) }
      let first = history.save(.init(messages: [.init(role: .assistant, text: "Stale")]), owner: owner)
      let later = history.save(.init(messages: [.init(role: .assistant, text: "Still stale")]), owner: owner)
      for pending in [first, later] {
        do {
          try await pending.value
          Issue.record("A stale snapshot or failed save chain overwrote another revision")
        } catch HanlinHostError.storeConflict { }
      }
      let (value, writes) = await store.snapshot()
      #expect(value == concurrent && writes == (phase == "during-cas" ? 1 : 0))
      // Only displaying the freshly loaded value establishes another write baseline.
      let reopened = UUID()
      let restored = try await history.activate(owner: reopened)
      #expect(restored == concurrentSnapshot)
      try await history.save(.init(messages: concurrentSnapshot.messages, draft: "New draft"), owner: reopened).value
      let (saved, finalWrites) = await store.snapshot()
      #expect(saved?.revision == 2 && finalWrites == writes + 1)
    }
  }

  @Test func cancellationPersistsPartialReplyAndOldEventsCannotChangeReopenedHistory() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scope = scope()
    let first = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory)
    await first.selectConversation(scope)
    let turn = try #require(first.beginResponse(prompt: "Interrupted request"))
    first.consume(.textDelta("Partial answer"), runID: turn.runID, responseID: turn.responseID)
    first.consume(.toolCall(.init(id: "pending", name: "create_task", argumentsJSON: "{}")),
      runID: turn.runID, responseID: turn.responseID)
    await first.cancel()
    let reopened = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory)
    await reopened.selectConversation(scope)
    let expected = reopened.messages
    #expect(expected.last?.text == "Partial answer")
    #expect(expected.last?.status == .cancelled)
    #expect(expected.last?.activities.last?.phase == .cancelled)
    first.consume(.textDelta("Must not appear"), runID: turn.runID, responseID: turn.responseID)
    first.finishResponse(runID: turn.runID, responseID: turn.responseID)
    first.updateDraft("Old owner draft", scope: scope)
    let again = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory)
    await again.selectConversation(scope)
    #expect(again.messages == expected && again.draft.isEmpty)
    #expect(again.pendingApproval == nil)
  }

  @Test func realSDKReceivesOrderedRolesAndSwitchingProviderDoesNotSendPriorHistory() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstScope = scope()
    let firstHistory = try LorvexHanlinConversationHistoryRegistry.history(scope: firstScope, directory: fixture.directory)
    let owner = UUID()
    _ = try await firstHistory.activate(owner: owner)
    try await firstHistory.save(.init(messages: [
      .init(role: .user, text: "Private A question"),
      .init(role: .assistant, text: "Private A answer"),
      .init(role: .status, text: "Saved create_task status must not be sent")
    ]), owner: owner).value
    let bodies = Mutex<[Data]>([])
    let response = try sse(text: "Continued") + sseFinish()
    let state = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory) {
      configuration, scope, directory, store, authorizer in
      let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
        if let body = request.httpBody { bodies.withLock { $0.append(body) } }
        return .init(body: .data(response), urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200,
          httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
      })
      return try self.bundle(core: fixture.core, scope: scope, store: store, engine: engine, authorizer: authorizer)
    }
    await state.send("A follow up", modelID: "fixture", endpoint: firstScope.endpoint,
      credential: "fixture-key", provider: firstScope.provider, scope: firstScope)
    #expect(state.errorMessage == nil)
    let firstBody = try #require(bodies.withLock { $0.first })
    let firstJSON = try #require(try JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
    let input = try #require(firstJSON["messages"] as? [[String: Any]])
      .filter { ["user", "assistant"].contains($0["role"] as? String ?? "") }
    #expect(input.compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
    let encoded = String(decoding: firstBody, as: UTF8.self)
    #expect(encoded.contains("Private A question") && encoded.contains("Private A answer"))
    #expect(!encoded.contains("Saved create_task status must not be sent"))

    let other = scope(account: "different-provider-account")
    await state.send("B only", modelID: "fixture", endpoint: other.endpoint,
      credential: "different-fixture-key", provider: other.provider, scope: other)
    #expect(state.errorMessage == nil)
    let otherBody = try #require(bodies.withLock { $0.last })
    let otherText = String(decoding: otherBody, as: UTF8.self)
    #expect(otherText.contains("B only"))
    #expect(!otherText.contains("Private A") && !otherText.contains("A follow up"))
    await state.selectConversation(firstScope)
    #expect(state.messages.contains { $0.text == "A follow up" })
    #expect(!state.messages.contains { $0.text == "B only" })
  }

  @Test func reopenedOwnerCannotAuthorizePreviousLiveSession() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scope = scope()
    let pipe = Mutex<AsyncThrowingStream<Data, Error>.Continuation?>(nil)
    let chunk = try sse(text: "Waiting")
    defer { pipe.withLock { $0?.finish() } }
    var capturedAuthorizer: LorvexHanlinHost.WriteAuthorizer?
    let old = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory) {
      configuration, scope, directory, store, authorizer in
      capturedAuthorizer = authorizer
      let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
        .init(body: .stream(AsyncThrowingStream { continuation in
          pipe.withLock { $0 = continuation }
          continuation.yield(chunk)
        }), urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200,
          httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
      })
      return try self.bundle(core: fixture.core, scope: scope, store: store, engine: engine, authorizer: authorizer)
    }
    let sending = _Concurrency.Task { @MainActor in
      await old.send("Old live session", modelID: "fixture", endpoint: scope.endpoint,
        credential: "fixture-key", provider: scope.provider, scope: scope)
    }
    try await eventually { old.messages.last?.text == "Waiting" && capturedAuthorizer != nil }
    let authorizer = try #require(capturedAuthorizer)
    let pending = _Concurrency.Task { @MainActor in
      await authorizer(.init(tool: "cancel_task", objectIDs: ["unused"], description: "Old destructive action"))
    }
    try await eventually { old.pendingApprovalID != nil }
    let requestID = try #require(old.pendingApprovalID)
    let reopened = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory)
    let restoring = _Concurrency.Task { @MainActor in await reopened.selectConversation(scope) }
    try await eventually { !old.isRunning }
    old.resolveApproval(true, requestID: requestID)
    pipe.withLock { $0?.finish() }
    await restoring.value
    let allowed = await pending.value
    #expect(!allowed)
    #expect(reopened.pendingApproval == nil && !reopened.isRunning)
    await sending.value
    let tasks = try await fixture.core.listTasks(
      status: "all", listID: nil, priority: nil, text: nil, limit: 10, offset: 0)
    #expect(tasks.tasks.isEmpty)
  }

  @Test func rapidProviderSwitchesWaitForTheActualPreviousSDKRetirement() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstScope = scope()
    let execution = HistoryRetirementGate()
    let cancellation = HistoryRetirementGate()
    defer {
      _Concurrency.Task {
        await cancellation.release()
        await execution.release()
      }
    }
    let response = try sse(text: "Account A completed") + sseFinish()
    var active: LorvexHanlinAgentBundle?
    let state = LorvexHanlinAssistantState(core: fixture.core, conversationDirectory: fixture.directory) {
      configuration, scope, directory, store, authorizer in
      let engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
        .init(body: .data(response), urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200,
          httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
      })
      let value = try self.bundle(core: fixture.core, scope: scope, store: store,
        engine: engine, authorizer: authorizer, sessionHost: { base in
          HistoryRetirementHost(base: base, execution: execution, cancellation: cancellation)
        })
      active = value
      return value
    }
    await state.send("Account A", modelID: "fixture", endpoint: firstScope.endpoint,
      credential: "fixture-key", provider: firstScope.provider, scope: firstScope)
    #expect(state.errorMessage == nil)
    let original = try #require(active)
    let catalog = try await original.host.catalog(for: original.identity.context)
    // Keep a real dispatcher reservation at the original host boundary. No task is mutated.
    let dispatch = _Concurrency.Task {
      try await original.agent.dispatcher.dispatch(alias: "list_tasks", argumentsJSON: "{}",
        providerCallID: "retirement-read", runID: UUID(), step: 0, session: original.identity,
        catalog: catalog, limits: .init())
    }
    try await eventually { execution.hasEntered }
    let selectingB = _Concurrency.Task { @MainActor in
      await state.selectConversation(self.scope(account: "profile-b"))
    }
    try await eventually { cancellation.hasEntered }
    var startedC = false
    var finishedC = false
    let finalScope = scope(account: "profile-c")
    let selectingC = _Concurrency.Task { @MainActor in
      startedC = true
      await state.selectConversation(finalScope)
      finishedC = true
    }
    try await eventually { startedC }
    // Allow the competing MainActor selection to resume while SDK invalidation is explicitly held.
    for _ in 0..<100 { await _Concurrency.Task<Never, Never>.yield() }
    #expect(!finishedC && !state.isConversationReady)
    await cancellation.release()
    await execution.release()
    await selectingB.value
    await selectingC.value
    _ = await dispatch.result
    #expect(finishedC && state.isConversationReady && state.conversationScope == finalScope)
    #expect(state.messages.isEmpty && state.pendingApproval == nil)
  }

  private struct Fixture {
    let root: URL
    let directory: URL
    let core: SwiftLorvexCoreService
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "lorvex-history-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Fixture(root: root, directory: root.appending(path: "conversations", directoryHint: .isDirectory),
      core: SwiftLorvexCoreService(databasePath: root.appending(path: "tasks.sqlite").path,
                                  writeInitiatorDefault: "user"))
  }

  private func scope(cloud: String? = "cloud-a", provider: String = "OpenAI",
                     endpoint: String = "https://fixture.invalid/v1",
                     account: String? = "profile-a") -> LorvexHanlinConversationScope {
    .init(lorvexAccountID: cloud, provider: provider, endpoint: endpoint, providerAccountID: account)
  }

  private func record(scope: LorvexHanlinConversationScope, revision: UInt64,
                      snapshot: LorvexHanlinConversationSnapshot) throws -> HanlinConversationRecord {
    try record(scope: scope, revision: revision,
      text: String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self))
  }

  private func record(scope: LorvexHanlinConversationScope, revision: UInt64,
                      text: String) throws -> HanlinConversationRecord {
    .init(namespace: try scope.displayNamespace, conversationID: scope.conversationID, revision: revision,
      entries: [
        .init(runID: scope.conversationID, step: 0, sequence: 0,
          payload: .presentationReference(version: 1, opaqueReference: "lorvex.assistant.display.v1")),
        .init(runID: scope.conversationID, step: 0, sequence: 1, payload: .text(text))
      ])
  }

  private func bundle(core: SwiftLorvexCoreService, scope: LorvexHanlinConversationScope,
                      store: any HanlinConversationStore, engine: HanlinAISDKAgentEngine,
                      authorizer: @escaping LorvexHanlinHost.WriteAuthorizer,
                      sessionHost: ((LorvexHanlinHost) -> any HanlinHostIntegration)? = nil) throws -> LorvexHanlinAgentBundle {
    let namespace = try HanlinConversationNamespace(
      app: "lorvex", account: scope.accountID, workspace: "personal", space: "tasks")
    let context = HanlinHostContext(namespace: namespace, sceneID: UUID(), generation: UUID())
    let identity = HanlinHostSession(conversationID: scope.conversationID, context: context)
    let host = LorvexHanlinHost(core: core, context: context, authorizeWrite: authorizer)
    return .init(host: host, agent: HanlinAgentSession(
      identity: identity, host: sessionHost?(host) ?? host, engine: engine, store: store), identity: identity)
  }

  private func eventually(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate(), ContinuousClock.now < deadline {
      try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(1))
    }
    try #require(predicate(), "The controlled stream did not reach its expected state")
  }

  private func sse(text: String) throws -> Data {
    let value: [String: Any] = [
      "id": "history-fixture", "object": "chat.completion.chunk", "created": 0, "model": "fixture",
      "choices": [["index": 0, "delta": ["role": "assistant", "content": text], "finish_reason": NSNull()]]
    ]
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return Data(("data: " + String(decoding: bytes, as: UTF8.self) + "\n\n").utf8)
  }

  private func sseFinish() -> Data {
    Data(#"data: {"id":"history-fixture","object":"chat.completion.chunk","created":0,"model":"fixture","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#.utf8)
      + Data("\n\ndata: [DONE]\n\n".utf8)
  }
}

private actor HistoryMemoryStore: HanlinConversationStore {
  private var value: HanlinConversationRecord?
  private let readFails: Bool
  private var conflictingReplacement: HanlinConversationRecord?
  private var writes = 0

  init(value: HanlinConversationRecord, readFails: Bool = false,
       conflictingReplacement: HanlinConversationRecord? = nil) {
    self.value = value
    self.readFails = readFails
    self.conflictingReplacement = conflictingReplacement
  }

  func load(_ id: UUID, namespace: HanlinConversationNamespace) async throws -> HanlinConversationRecord? {
    if readFails { throw CocoaError(.fileReadCorruptFile) }
    return value
  }

  func save(_ record: HanlinConversationRecord, replacing revision: UInt64?) async throws {
    writes += 1
    if let conflictingReplacement {
      value = conflictingReplacement
      self.conflictingReplacement = nil
      throw HanlinHostError.storeConflict
    }
    guard revision == value?.revision else { throw HanlinHostError.storeConflict }
    value = record
  }

  func delete(_ id: UUID, namespace: HanlinConversationNamespace, replacing revision: UInt64) async throws {
    guard revision == value?.revision else { throw HanlinHostError.storeConflict }
    value = nil
  }

  func replaceFromExternalWriter(_ record: HanlinConversationRecord) { value = record }

  func snapshot() -> (HanlinConversationRecord?, Int) { (value, writes) }
}


// This test gate delays only the original host boundary; it grants no authority.
private actor HistoryRetirementGate {
  nonisolated private let entered = Mutex(false)
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var released = false

  nonisolated var hasEntered: Bool { entered.withLock { $0 } }

  func wait() async {
    entered.withLock { $0 = true }
    guard !released else { return }
    await withCheckedContinuation { continuations.append($0) }
  }

  func release() {
    released = true
    let pending = continuations
    continuations = []
    for continuation in pending { continuation.resume() }
  }
}

private actor HistoryRetirementHost: HanlinHostIntegration {
  nonisolated let apiVersion = HanlinAPIVersion(major: 1, minor: 1)
  private let base: LorvexHanlinHost
  private let execution: HistoryRetirementGate
  private let cancellation: HistoryRetirementGate

  init(base: LorvexHanlinHost, execution: HistoryRetirementGate, cancellation: HistoryRetirementGate) {
    self.base = base; self.execution = execution; self.cancellation = cancellation
  }

  func context(for session: HanlinHostSession) async throws -> HanlinHostContext {
    try await base.context(for: session)
  }

  func catalog(for context: HanlinHostContext) async throws -> HanlinHostCatalog {
    try await base.catalog(for: context)
  }

  func execute(_ invocation: HanlinHostInvocation,
               progress: @escaping HanlinHostProgressHandler) async throws -> HanlinHostExecutionResult {
    await execution.wait()
    return try await base.execute(invocation, progress: progress)
  }

  func cancel(_ invocation: HanlinToolInvocationID) async {
    await base.cancel(invocation)
    await cancellation.wait()
  }

  func open(_ destination: HanlinHostDestination) async throws -> HanlinHostNavigationResult {
    try await base.open(destination)
  }
}
