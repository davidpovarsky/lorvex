import Foundation
import CryptoKit
import Observation
import LorvexCore
import HanlinAgentCore
import HanlinChatCore
import HanlinHostContracts

/// Native chart state derived from the get_summary tool's actual JSON payload.
/// It is read-only: chart controls never mutate task data.
public struct LorvexHanlinSummary: Decodable, Sendable {
  public let totalMatching: Int
  public let sampleSize: Int
  public let partial: Bool
  public let open: Int
  public let completed: Int
  public let byPriority: [String: Int]
  public let byStatus: [String: Int]

  public struct Bucket: Identifiable, Sendable {
    public let name: String
    public let value: Int
    public var id: String { name }
  }
  public func buckets(by breakdown: String) -> [Bucket] {
    let values = breakdown == "priority" ? byPriority : byStatus
    return values.map { Bucket(name: $0.key, value: $0.value) }
      .sorted { $0.name < $1.name }
  }
}

/// One live conversation owner for Lorvex's actual HanlinAgentSession. The app
/// retains this owner when the sheet closes; presentation never creates an engine.
@MainActor @Observable
public final class LorvexHanlinAssistantState {
  public private(set) var messages: [LorvexHanlinMessage] = []
  public private(set) var isRunning = false
  public private(set) var errorMessage: String?
  public private(set) var pendingApproval: LorvexHanlinWriteRequest?
  public private(set) var pendingApprovalID: UUID?
  public private(set) var dashboard: LorvexHanlinSummary?
  public private(set) var contentRevision: UInt64 = 0
  public private(set) var conversationID: UUID
  public private(set) var conversationScope: LorvexHanlinConversationScope?
  public private(set) var isRestoringConversation = false
  public private(set) var isConversationReady = false
  public private(set) var conversationRevision: UInt64 = 0
  public private(set) var draft = ""

  @ObservationIgnored private let conversationDirectory: URL?
  @ObservationIgnored private var history: LorvexHanlinConversationHistory?
  @ObservationIgnored private var historyOwner: UUID?
  @ObservationIgnored private var restorationID: UUID?
  @ObservationIgnored private var lastHistoryCheckpoint: ContinuousClock.Instant?
  @ObservationIgnored private var bundleFactory: BundleFactory?

  typealias BundleFactory = @MainActor (
    HanlinChatModelConfiguration, LorvexHanlinConversationScope, URL,
    any HanlinConversationStore, @escaping LorvexHanlinHost.WriteAuthorizer
  ) throws -> LorvexHanlinAgentBundle

  @ObservationIgnored private let core: any LorvexCoreServicing
  @ObservationIgnored private let didWrite: @Sendable () async -> Void
  @ObservationIgnored private var bundle: LorvexHanlinAgentBundle?
  @ObservationIgnored private var pendingRetirement: _Concurrency.Task<Void, Never>?
  @ObservationIgnored private var modelIdentity: ModelIdentity?
  @ObservationIgnored private var sessionID: UUID?
  @ObservationIgnored private var activeRunID: UUID?
  @ObservationIgnored private var activeResponseID: UUID?
  @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?

  struct ModelIdentity: Equatable {
    let provider: String
    let endpoint: String
    let modelID: String
    let credentialDigest: Data

    init(provider: String, endpoint: String, modelID: String, credential: String) {
      self.provider = provider; self.endpoint = endpoint; self.modelID = modelID
      credentialDigest = Data(SHA256.hash(data: Data(credential.utf8)))
    }
  }

  public init(core: any LorvexCoreServicing,
              conversationID: UUID = UUID(),
              conversationDirectory: URL? = nil,
              didWrite: @escaping @Sendable () async -> Void = {}) {
    self.core = core; self.conversationID = conversationID; self.didWrite = didWrite
    self.conversationDirectory = conversationDirectory
  }

  convenience init(core: any LorvexCoreServicing, conversationDirectory: URL,
                   bundleFactory: @escaping BundleFactory) {
    self.init(core: core, conversationDirectory: conversationDirectory)
    self.bundleFactory = bundleFactory
  }

  private var ownsConversation: Bool {
    guard let history, let historyOwner else { return false }
    return history.isOwned(by: historyOwner)
  }

  /// Select only this provider/account's display record. Restored content has no live admission.
  public func selectConversation(_ scope: LorvexHanlinConversationScope?) async {
    if scope == conversationScope, isConversationReady, ownsConversation { return }
    let requestID = UUID(), owner = UUID()
    restorationID = requestID
    isRestoringConversation = true
    isConversationReady = false
    await cancel()
    guard restorationID == requestID else { return }
    if let historyOwner { history?.deactivate(owner: historyOwner) }
    history = nil; historyOwner = nil
    conversationScope = scope
    messages = []; draft = ""; dashboard = nil; errorMessage = nil
    contentRevision &+= 1
    defer {
      if restorationID == requestID {
        restorationID = nil
        isRestoringConversation = false
        conversationRevision &+= 1
      }
    }
    guard let scope else { return }
    var selected: LorvexHanlinConversationHistory?
    do {
      let directory: URL
      if let conversationDirectory { directory = conversationDirectory }
      else {
        guard let support = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask).first else {
          throw CocoaError(.fileNoSuchFile)
        }
        directory = support.appending(path: "LorvexHanlinConversations", directoryHint: .isDirectory)
      }
      let next = try LorvexHanlinConversationHistoryRegistry.history(scope: scope, directory: directory)
      selected = next
      let snapshot = try await next.activate(owner: owner) { [weak self] in
        guard let self, self.historyOwner == owner || self.restorationID == requestID else {
          return _Concurrency.Task {}
        }
        return self.cancelCurrentRequest()
      }
      try _Concurrency.Task<Never, Never>.checkCancellation()
      guard restorationID == requestID, next.isOwned(by: owner) else {
        next.deactivate(owner: owner)
        return
      }
      history = next; historyOwner = owner
      conversationID = scope.conversationID
      messages = (snapshot?.messages ?? []).map { $0.restoredForDisplay() }
      draft = snapshot?.draft ?? ""
      dashboard = messages.reversed().lazy.flatMap { $0.activities.reversed() }
        .first(where: { $0.name == "get_summary" && $0.phase == .completed })
        .flatMap { try? JSONDecoder().decode(LorvexHanlinSummary.self, from: Data($0.result.utf8)) }
      lastHistoryCheckpoint = nil
      isConversationReady = true
      contentRevision &+= 1
    } catch {
      selected?.deactivate(owner: owner)
      guard restorationID == requestID else { return }
      if error is CancellationError || _Concurrency.Task<Never, Never>.isCancelled { return }
      errorMessage = String(localized: "The saved conversation could not be read. Its existing data has been preserved.")
    }
  }

  public func updateDraft(_ value: String, scope: LorvexHanlinConversationScope?) {
    guard isConversationReady, ownsConversation, conversationScope == scope, draft != value else { return }
    draft = value
    _ = saveConversation()
  }

  public func setActivityExpanded(_ expanded: Bool, messageID: UUID, activityID: String) {
    guard isConversationReady, ownsConversation,
          let index = messages.firstIndex(where: { $0.id == messageID }),
          messages[index].activities.contains(where: { $0.id == activityID }) else { return }
    if expanded { messages[index].expandedActivityIDs.insert(activityID) }
    else { messages[index].expandedActivityIDs.remove(activityID) }
    contentRevision &+= 1
    _ = saveConversation()
  }

  public func setReasoningExpanded(_ expanded: Bool, messageID: UUID) {
    guard isConversationReady, ownsConversation,
          let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
    messages[index].reasoningExpanded = expanded
    contentRevision &+= 1
    _ = saveConversation()
  }

  @discardableResult
  private func saveConversation() -> _Concurrency.Task<Void, Error>? {
    guard let history, let owner = historyOwner, history.isOwned(by: owner) else { return nil }
    let saving = history.save(.init(messages: messages, draft: draft), owner: owner)
    _Concurrency.Task { @MainActor [weak self] in
      if case .failure = await saving.result,
         let self, self.historyOwner == owner, history.isOwned(by: owner) {
        self.isConversationReady = false
        self.errorMessage = String(localized: "The conversation could not be saved. Its existing data has been preserved.")
      }
    }
    return saving
  }

  private func checkpointConversation() {
    let now = ContinuousClock.now
    guard lastHistoryCheckpoint.map({ $0.duration(to: now) >= .milliseconds(500) }) ?? true else { return }
    lastHistoryCheckpoint = now
    _ = saveConversation()
  }

  func flushConversation() async throws { if let history { try await history.flush() } }

  func providerHistory(excluding responseID: UUID) -> [HanlinAISDKMessage] {
    messages.filter { $0.role != .status && $0.id != responseID && !$0.text.isEmpty }
      .map { HanlinAISDKMessage(role: $0.role == .user ? .user : .assistant, text: $0.text) }
  }

  public func resolveApproval(_ authorized: Bool, requestID: UUID? = nil) {
    if let requestID, requestID != pendingApprovalID { return }
    let current = approval
    approval = nil; pendingApproval = nil; pendingApprovalID = nil
    current?.resume(returning: authorized && (history == nil || ownsConversation))
  }

  private func approve(_ request: LorvexHanlinWriteRequest, session: UUID) async -> Bool {
    guard sessionID == session, activeRunID != nil, (history == nil || ownsConversation),
          pendingApproval == nil, approval == nil,
          !_Concurrency.Task<Never, Never>.isCancelled else { return false }
    if LorvexHanlinWritePolicy.mayAutomaticallyAuthorize(request.tool) { return true }
    let requestID = UUID()
    let allowed = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        guard sessionID == session, activeRunID != nil,
              !_Concurrency.Task<Never, Never>.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        pendingApproval = request; pendingApprovalID = requestID
        approval = continuation
      }
    } onCancel: {
      _Concurrency.Task { @MainActor [weak self] in
        self?.resolveApproval(false, requestID: requestID)
      }
    }
    return allowed && sessionID == session && activeRunID != nil
      && (history == nil || ownsConversation) && !_Concurrency.Task<Never, Never>.isCancelled
  }

  public func cancel() async { await cancelCurrentRequest().value }

  @discardableResult
  private func cancelCurrentRequest() -> _Concurrency.Task<Void, Never> {
    // Revoke ownership before the first suspension. A late completion from this
    // session may not clear or append to the next request started by the user.
    let previous = bundle
    let responseID = activeResponseID
    activeRunID = nil; activeResponseID = nil
    bundle = nil; sessionID = nil; modelIdentity = nil; isRunning = false
    resolveApproval(false)
    if let responseID, let index = messages.firstIndex(where: { $0.id == responseID }) {
      messages[index].finish(.cancelled)
      contentRevision &+= 1
    }
    return retire(previous, saving: saveConversation())
  }

  private func retire(_ previous: LorvexHanlinAgentBundle?,
                      saving: _Concurrency.Task<Void, Error>? = nil) -> _Concurrency.Task<Void, Never> {
    // Keep the actual retirement even after bundle has been cleared. A rapid
    // A/B/C provider switch must await A before C may acquire live authority.
    let earlier = pendingRetirement
    let operation = _Concurrency.Task { @MainActor in
      if let earlier { await earlier.value }
      if let previous { await previous.agent.invalidate() }
      if let saving { _ = await saving.result }
    }
    pendingRetirement = operation
    return operation
  }

  func beginResponse(prompt: String) -> (runID: UUID, responseID: UUID)? {
    guard !isRunning else { return nil }
    let runID = UUID(), responseID = UUID()
    activeRunID = runID; activeResponseID = responseID
    isRunning = true; errorMessage = nil
    messages.append(.init(role: .user, text: prompt))
    messages.append(.init(id: responseID, role: .assistant, text: "", status: .streaming))
    contentRevision &+= 1
    _ = saveConversation()
    return (runID, responseID)
  }

  func consume(_ event: HanlinAISDKStreamEvent, runID: UUID, responseID: UUID) {
    guard activeRunID == runID, activeResponseID == responseID, (history == nil || ownsConversation),
          let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
    messages[index].consume(event)
    if case .toolResult(_, let name, let text, _, let isError) = event,
       !isError, name == "get_summary",
       let bytes = text.data(using: .utf8),
       let summary = try? JSONDecoder().decode(LorvexHanlinSummary.self, from: bytes) {
      dashboard = summary
    }
    contentRevision &+= 1
    checkpointConversation()
  }

  func finishResponse(runID: UUID, responseID: UUID, failure: String? = nil) {
    guard activeRunID == runID, activeResponseID == responseID,
          (history == nil || ownsConversation) else { return }
    if let index = messages.firstIndex(where: { $0.id == responseID }) {
      let terminal: LorvexHanlinMessage.Status = failure == nil ? .completed : .failed
      messages[index].finish(terminal)
      if messages[index].text.isEmpty, messages[index].status != .cancelled {
        messages[index].text = failure == nil
          ? String(localized: "No answer text. Check activity and retry.")
          : String(localized: "The request failed.")
      }
    }
    errorMessage = failure
    activeRunID = nil; activeResponseID = nil; isRunning = false
    resolveApproval(false)
    contentRevision &+= 1
    _ = saveConversation()
  }

  public func send(_ input: String, modelID: String, endpoint: String,
                   credential: String, provider: String,
                   scope: LorvexHanlinConversationScope? = nil) async {
    let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isRunning, !prompt.isEmpty else { return }
    if let scope { await selectConversation(scope) }
    guard !_Concurrency.Task<Never, Never>.isCancelled,
          isConversationReady, ownsConversation, let selectedScope = conversationScope,
          scope == nil || scope == selectedScope,
          selectedScope.provider == provider, selectedScope.endpoint == endpoint else { return }
    guard !modelID.isEmpty, !credential.isEmpty,
          let url = URL(string: endpoint), url.scheme == "https", url.host != nil else {
      errorMessage = String(localized: "Configure a model, HTTPS provider endpoint, and API key.")
      return
    }
    draft = ""
    guard let turn = beginResponse(prompt: prompt) else { return }
    let runID = turn.runID, responseID = turn.responseID

    do {
      try await flushConversation()
      try _Concurrency.Task<Never, Never>.checkCancellation()
      guard activeRunID == runID, ownsConversation, conversationScope == selectedScope else { return }
      let identity = ModelIdentity(provider: provider, endpoint: endpoint,
                                   modelID: modelID, credential: credential)
      if bundle == nil || modelIdentity != identity {
        let previous = bundle
        bundle = nil; sessionID = nil; modelIdentity = nil
        await retire(previous).value
        try _Concurrency.Task<Never, Never>.checkCancellation()
        guard activeRunID == runID else { return }
        let fromChatGPTPlan = provider == "ChatGPT"
        let configuration = HanlinChatModelConfiguration(
          modelID: modelID, company: fromChatGPTPlan ? "OpenAI" : provider,
          apiType: fromChatGPTPlan ? "openai-chatgpt-plan" :
                   provider == "Anthropic" ? "Anthropic" :
                   provider == "Google" ? "Gemini" : "OpenAI",
          endpoint: url, apiKey: credential,
          supportsToolUse: true)
        guard let scope = conversationScope, let history, ownsConversation else {
          throw CancellationError()
        }
        let owner = UUID()
        let authorize: LorvexHanlinHost.WriteAuthorizer = { [weak self] request in
          guard let self else { return false }
          return await self.approve(request, session: owner)
        }
        if let bundleFactory {
          bundle = try bundleFactory(configuration, scope, history.directory, history.store, authorize)
        } else {
          bundle = try LorvexHanlinAgentFactory.make(
            core: core, configuration: configuration, accountID: scope.accountID,
            directory: history.directory, conversationStore: history.store, conversationID: conversationID,
            authorizeWrite: authorize, didWrite: didWrite)
        }
        sessionID = owner; modelIdentity = identity
      }
      guard activeRunID == runID, let bundle else { return }
      let history = providerHistory(excluding: responseID)
      let events = try await bundle.agent.stream(
        messages: history,
        systemPrompt: "You are the personal planning assistant inside Lorvex. "
          + "Use the exposed Lorvex tools to read and manage the user's real planning data. "
          + "Routine task, list, habit and calendar changes are authorized by the user's request. "
          + "Ask for consent for destructive writes. "
          + "Report data faithfully; do not claim a change before the tool confirms it. "
          + "Use show_task_workspace to present interactive real tasks after creating or planning related tasks, "
          + "or when the user asks for a graph, board, timeline, network, table or matrix. "
          + "Matrix groups canonical priority and deadline; planned work days remain independent. "
          + "Use exact task IDs and add_task_dependency/remove_task_dependency for real prerequisites. "
          + "A task's depends_on IDs identify work that must finish before that task can start. "
          + "Respond in the user's language, including Hebrew.",
        modelReference: .init(provider: provider, modelID: modelID), maxSteps: 8)
      guard activeRunID == runID else { return }
      for try await item in events {
        try _Concurrency.Task<Never, Never>.checkCancellation()
        guard activeRunID == runID else { return }
        consume(item.event, runID: runID, responseID: responseID)
      }
      finishResponse(runID: runID, responseID: responseID)
      try await flushConversation()
    } catch {
      guard activeRunID == runID else { return }
      if error is CancellationError || _Concurrency.Task<Never, Never>.isCancelled {
        await cancel()
      } else {
        finishResponse(runID: runID, responseID: responseID, failure: LorvexHanlinErrorMessage.description(for: error))
      }
    }
  }
}
