import Foundation
import LorvexCore
import HanlinAgentCore
import HanlinChatCore
import HanlinHostContracts
import HanlinPersistenceAdapters

@MainActor
public struct LorvexHanlinAgentBundle {
  public let host: LorvexHanlinHost
  public let agent: HanlinAgentSession
  public let identity: HanlinHostSession
}

@MainActor
public enum LorvexHanlinAgentFactory {
  /// Constructs the actual existing Hanlin agent SDK on the canonical Lorvex
  /// Core service. Never creates a second CoreService or task database.
  public static func make(
    core: any LorvexCoreServicing,
    configuration: HanlinChatModelConfiguration,
    accountID: String,
    directory: URL,
    conversationID: UUID = UUID(),
    sceneID: UUID = UUID(),
    authorizeWrite: @escaping LorvexHanlinHost.WriteAuthorizer = { _ in false },
    didWrite: @escaping @Sendable () async -> Void = {}
  ) throws -> LorvexHanlinAgentBundle {
    let namespace = try HanlinConversationNamespace(
      app: "lorvex", account: accountID, workspace: "personal", space: "tasks")
    let context = HanlinHostContext(
      namespace: namespace, sceneID: sceneID, generation: UUID(),
      objectReference: "lorvex-personal", localeIdentifier: Locale.current.identifier)
    let identity = HanlinHostSession(conversationID: conversationID, context: context)
    let host = LorvexHanlinHost(core: core, context: context,
                                authorizeWrite: authorizeWrite, didWrite: didWrite)
    let engine = try HanlinAISDKAgentEngine(configuration: configuration)
    let persistence = try HanlinPrivateConversationStore(directory: directory)
    let agent = HanlinAgentSession(identity: identity, host: host,
                                    engine: engine, store: persistence)
    // Provider approval merely moves to the host's *independent* UI check.
    // The model cannot authorize native writes on its own.
    agent.onProviderToolApproval = { _ in true }
    return .init(host: host, agent: agent, identity: identity)
  }
}
