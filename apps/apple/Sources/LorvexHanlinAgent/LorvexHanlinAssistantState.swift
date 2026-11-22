import Foundation
import Observation
import LorvexCore
import HanlinAgentCore
import HanlinChatCore
import HanlinHostContracts

public struct LorvexHanlinMessage: Identifiable, Sendable {
  public enum Role: String, Sendable { case user, assistant, status }
  public let id: UUID
  public let role: Role
  public var text: String
  public init(id: UUID = UUID(), role: Role, text: String) {
    self.id = id; self.role = role; self.text = text
  }
}

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

/// Streamed native Chat UI state backed by the real HanlinAgentSession.
/// User approvals cannot be silently bypassed; default is deny.
@MainActor @Observable
public final class LorvexHanlinAssistantState {
  public private(set) var messages: [LorvexHanlinMessage] = []
  public private(set) var isRunning = false
  public private(set) var errorMessage: String?
  public private(set) var pendingApproval: LorvexHanlinWriteRequest?
  public private(set) var dashboard: LorvexHanlinSummary?

  @ObservationIgnored private let core: any LorvexCoreServicing
  @ObservationIgnored private let didWrite: @Sendable () async -> Void
  @ObservationIgnored private var bundle: LorvexHanlinAgentBundle?
  @ObservationIgnored private var modelFingerprint: String?
  @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private let conversationID: UUID

  public init(core: any LorvexCoreServicing,
              conversationID: UUID = UUID(),
              didWrite: @escaping @Sendable () async -> Void = {}) {
    self.core = core; self.conversationID = conversationID; self.didWrite = didWrite
  }

  public func resolveApproval(_ authorized: Bool) {
    let current = approval
    approval = nil
    pendingApproval = nil
    current?.resume(returning: authorized)
  }

  private func approve(_ request: LorvexHanlinWriteRequest) async -> Bool {
    guard pendingApproval == nil, approval == nil,
          !_Concurrency.Task<Never,Never>.isCancelled else { return false }
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<Bool, Never>) in
      pendingApproval = request
      approval = continuation
    }
  }

  public func cancel() async {
    resolveApproval(false)
    if let bundle { await bundle.agent.invalidate() }
    bundle = nil; modelFingerprint = nil; isRunning = false
  }

  public func send(_ input: String, modelID: String, endpoint: String,
                   credential: String, provider: String) async {
    let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isRunning, !prompt.isEmpty else { return }
    guard !modelID.isEmpty, !credential.isEmpty,
          let url = URL(string: endpoint), url.scheme == "https", url.host != nil else {
      errorMessage = "Configure a model, HTTPS provider endpoint, and API key."
      return
    }

    isRunning = true; errorMessage = nil
    messages.append(.init(role: .user, text: prompt))
    let responseID = UUID()
    messages.append(.init(id: responseID, role: .assistant, text: ""))
    defer { isRunning = false }

    do {
      let identity = "\(provider)|\(endpoint)|\(modelID)"
      if bundle == nil || modelFingerprint != identity {
        if let previous = bundle { await previous.agent.invalidate() }
        let configuration = HanlinChatModelConfiguration(
          modelID: modelID, company: provider,
          apiType: provider == "Anthropic" ? "Anthropic" :
                   provider == "Google" ? "Gemini" : "OpenAI",
          endpoint: url, apiKey: credential,
          supportsToolUse: true)
        let support = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appending(
          path: "LorvexHanlinConversations", directoryHint: .isDirectory)
        bundle = try LorvexHanlinAgentFactory.make(
          core: core, configuration: configuration, accountID: "device-local",
          directory: directory, conversationID: conversationID,
          authorizeWrite: { [weak self] request in
            guard let self else { return false }
            return await self.approve(request)
          },
          didWrite: didWrite)
        modelFingerprint = identity
      }
      guard let bundle else { throw HanlinHostError.invalidContext }
      let history: [HanlinAISDKMessage] = messages
        .filter { $0.role != .status && $0.id != responseID }
        .map {
          HanlinAISDKMessage(role: $0.role == .user ? .user : .assistant, text: $0.text)
        }
      let events = try await bundle.agent.stream(
        messages: history,
        systemPrompt: "You are the personal planning assistant inside Lorvex. "
          + "Use only exposed Lorvex tools. Ask for consent for every write. "
          + "Report data faithfully; do not claim a change before host confirmation.",
        modelReference: .init(provider: provider, modelID: modelID),
        maxSteps: 8)
      for try await item in events {
        switch item.event {
        case .textDelta(let delta):
          if let index = messages.firstIndex(where: { $0.id == responseID }) {
            messages[index].text += delta
          }
        case .toolResult(_, let name, let modelText, _, let isError):
          if !isError, name == "get_summary",
             let json = modelText.data(using: .utf8),
             let summary = try? JSONDecoder().decode(LorvexHanlinSummary.self, from: json) {
            dashboard = summary
          }
          messages.append(.init(role: .status,
            text: (isError ? "Tool error: " : "Tool complete: ") + name))
        case .toolApprovalRequest(let request):
          messages.append(.init(role: .status, text: "Review tool " + request.toolName))
        default: break
        }
      }
      if let index = messages.firstIndex(where: { $0.id == responseID }),
         messages[index].text.isEmpty {
        messages[index].text = "No answer text. Check activity and retry."
      }
    } catch {
      errorMessage = error.localizedDescription
      if let index = messages.firstIndex(where: { $0.id == responseID }),
         messages[index].text.isEmpty {
        messages[index].text = "The request failed."
      }
    }
  }
}
