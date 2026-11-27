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
  public let conversationID: UUID

  @ObservationIgnored private let core: any LorvexCoreServicing
  @ObservationIgnored private let didWrite: @Sendable () async -> Void
  @ObservationIgnored private var bundle: LorvexHanlinAgentBundle?
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
              didWrite: @escaping @Sendable () async -> Void = {}) {
    self.core = core; self.conversationID = conversationID; self.didWrite = didWrite
  }

  public func resolveApproval(_ authorized: Bool, requestID: UUID? = nil) {
    if let requestID, requestID != pendingApprovalID { return }
    let current = approval
    approval = nil; pendingApproval = nil; pendingApprovalID = nil
    current?.resume(returning: authorized)
  }

  private func approve(_ request: LorvexHanlinWriteRequest, session: UUID) async -> Bool {
    guard sessionID == session, activeRunID != nil,
          pendingApproval == nil, approval == nil,
          !_Concurrency.Task<Never, Never>.isCancelled else { return false }
    if LorvexHanlinWritePolicy.mayAutomaticallyAuthorize(request.tool) { return true }
    let requestID = UUID()
    return await withTaskCancellationHandler {
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
  }

  public func cancel() async {
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
    if let previous { await previous.agent.invalidate() }
  }

  func beginResponse(prompt: String) -> (runID: UUID, responseID: UUID)? {
    guard !isRunning else { return nil }
    let runID = UUID(), responseID = UUID()
    activeRunID = runID; activeResponseID = responseID
    isRunning = true; errorMessage = nil
    messages.append(.init(role: .user, text: prompt))
    messages.append(.init(id: responseID, role: .assistant, text: "", status: .streaming))
    contentRevision &+= 1
    return (runID, responseID)
  }

  func consume(_ event: HanlinAISDKStreamEvent, runID: UUID, responseID: UUID) {
    guard activeRunID == runID, activeResponseID == responseID,
          let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
    messages[index].consume(event)
    if case .toolResult(_, let name, let text, _, let isError) = event,
       !isError, name == "get_summary",
       let bytes = text.data(using: .utf8),
       let summary = try? JSONDecoder().decode(LorvexHanlinSummary.self, from: bytes) {
      dashboard = summary
    }
    contentRevision &+= 1
  }

  func finishResponse(runID: UUID, responseID: UUID, failure: String? = nil) {
    guard activeRunID == runID, activeResponseID == responseID else { return }
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
  }

  public func send(_ input: String, modelID: String, endpoint: String,
                   credential: String, provider: String) async {
    let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isRunning, !prompt.isEmpty else { return }
    guard !modelID.isEmpty, !credential.isEmpty,
          let url = URL(string: endpoint), url.scheme == "https", url.host != nil else {
      errorMessage = String(localized: "Configure a model, HTTPS provider endpoint, and API key.")
      return
    }
    guard let turn = beginResponse(prompt: prompt) else { return }
    let runID = turn.runID, responseID = turn.responseID

    do {
      let identity = ModelIdentity(provider: provider, endpoint: endpoint,
                                   modelID: modelID, credential: credential)
      if bundle == nil || modelIdentity != identity {
        let previous = bundle
        bundle = nil; sessionID = nil; modelIdentity = nil
        if let previous { await previous.agent.invalidate() }
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
        guard let support = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask).first else {
          throw CocoaError(.fileNoSuchFile)
        }
        let directory = support.appending(
          path: "LorvexHanlinConversations", directoryHint: .isDirectory)
        let owner = UUID()
        bundle = try LorvexHanlinAgentFactory.make(
          core: core, configuration: configuration, accountID: "device-local",
          directory: directory, conversationID: conversationID,
          authorizeWrite: { [weak self] request in
            guard let self else { return false }
            return await self.approve(request, session: owner)
          }, didWrite: didWrite)
        sessionID = owner; modelIdentity = identity
      }
      guard activeRunID == runID, let bundle else { return }
      let history: [HanlinAISDKMessage] = messages
        .filter { $0.role != .status && $0.id != responseID && !$0.text.isEmpty }
        .map { HanlinAISDKMessage(role: $0.role == .user ? .user : .assistant, text: $0.text) }
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
