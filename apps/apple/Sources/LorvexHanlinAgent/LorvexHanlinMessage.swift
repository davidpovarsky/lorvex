import Foundation
import HanlinChatCore
import HanlinPlatformContracts

/// Presentation of observed canonical SDK events, keyed by their real call IDs.
/// This contains no tool execution or planning implementation.
public struct LorvexHanlinMessage: Identifiable, Codable, Equatable, Sendable {
  public enum Role: String, Codable, Sendable { case user, assistant, status }
  public enum Status: String, Codable, Sendable { case streaming, completed, failed, cancelled }
  public let id: UUID
  public let role: Role
  public var text: String
  public private(set) var reasoning = ""
  public private(set) var status: Status
  public private(set) var activities: [LorvexHanlinToolActivity] = []
  public private(set) var sources: [LorvexHanlinSource] = []
  public private(set) var workspaces: [LorvexHanlinTaskWorkspace] = []
  public private(set) var structuredParts: [HanlinChatStructuredPart] = []
  public var expandedActivityIDs: Set<String> = []
  public var reasoningExpanded = false

  public init(id: UUID = UUID(), role: Role, text: String, status: Status = .completed) {
    self.id = id; self.role = role; self.text = text; self.status = status
  }

  mutating func consume(_ event: HanlinAISDKStreamEvent) {
    switch event {
    case .textDelta(let text): self.text += text
    case .reasoningDelta(let text): reasoning += text
    case .structuredPart(let part):
      if !structuredParts.contains(part) { structuredParts.append(part) }
    case .toolCallArgumentsStarted(let id, let name):
      updateTool(id: id, name: name) { $0.phase = .preparing }
    case .toolCallArgumentsDelta(let id, let delta):
      updateTool(id: id) { $0.arguments += delta }
    case .toolCall(let call):
      updateTool(id: call.id, name: call.name) {
        $0.arguments = call.argumentsJSON; $0.phase = .running
      }
    case .toolApprovalRequest(let request):
      updateTool(id: request.toolCallID, name: request.toolName) {
        $0.arguments = request.argumentsJSON; $0.phase = .awaitingApproval
      }
    case .toolApprovalResolved(let request, let allowed):
      updateTool(id: request.toolCallID, name: request.toolName) {
        $0.phase = allowed ? .running : .denied
        if !allowed { $0.completedAt = Date() }
      }
    case .toolOutputDenied(let id, let name):
      updateTool(id: id, name: name) { $0.phase = .denied; $0.completedAt = Date() }
    case .toolResult(let id, let name, let result, _, let isError):
      if name == "show_task_workspace", !isError,
        let request = LorvexHanlinTaskWorkspace(callID: id, resultJSON: result) {
        workspaces.removeAll { $0.id == id }
        workspaces.append(request)
      }
      updateTool(id: id, name: name) {
        $0.result = result; $0.phase = isError ? .failed : .completed
        $0.completedAt = Date()
      }
    case .source(let id, let url, let title):
      addSource(id: id, url: url, title: title)
    case .textCitations(let citations):
      for citation in citations { addSource(id: citation.url, url: citation.url, title: citation.title) }
    case .cancelled: finish(.cancelled)
    default: break
    }
  }

  mutating func finish(_ terminal: Status) {
    guard status == .streaming else { return }
    status = terminal
    for index in activities.indices where activities[index].phase.isActive {
      // No tool result was observed. Completion of text never invents a
      // successful write receipt for a still-pending activity.
      activities[index].phase = terminal == .cancelled ? .cancelled : .incomplete
      activities[index].completedAt = Date()
    }
  }

  func restoredForDisplay() -> Self {
    var restored = self
    // An interrupted display never resumes a stream or a pending tool approval.
    restored.finish(.cancelled)
    return restored
  }

  private mutating func updateTool(id: String, name: String? = nil,
                                   change: (inout LorvexHanlinToolActivity) -> Void) {
    if let index = activities.firstIndex(where: { $0.id == id }) {
      if let name { activities[index].name = name }
      change(&activities[index])
    } else {
      var activity = LorvexHanlinToolActivity(id: id, name: name ?? "Tool")
      change(&activity); activities.append(activity)
    }
  }

  private mutating func addSource(id: String, url: String, title: String?) {
    guard let address = URL(string: url), ["https", "http"].contains(address.scheme ?? ""),
          address.host != nil else { return }
    if let index = sources.firstIndex(where: { $0.id == id || $0.url == address }) {
      if let title, !title.isEmpty { sources[index].title = title }
    } else {
      sources.append(.init(id: id, title: title ?? address.host ?? url, url: address))
    }
  }
}

public struct LorvexHanlinSource: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public var title: String
  public let url: URL
}

public struct LorvexHanlinToolActivity: Identifiable, Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable {
    case preparing, awaitingApproval, running, completed, failed, denied, cancelled, incomplete
    public var isActive: Bool { self == .preparing || self == .awaitingApproval || self == .running }
  }
  public let id: String
  public var name: String
  public var phase: Phase = .preparing
  public var arguments = ""
  public var result = ""
  public let startedAt: Date
  public var completedAt: Date?

  public init(id: String, name: String, startedAt: Date = Date()) {
    self.id = id; self.name = name; self.startedAt = startedAt
  }
}
