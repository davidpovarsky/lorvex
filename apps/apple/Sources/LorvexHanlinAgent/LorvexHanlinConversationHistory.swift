import CryptoKit
import Foundation
import HanlinHostContracts
import HanlinPersistenceAdapters
import HanlinPlatformContracts

/// Opaque identity for a Lorvex account and a stable provider account/profile.
/// OAuth bearer and refresh tokens never contribute to the saved namespace.
public struct LorvexHanlinConversationScope: Hashable, Sendable {
  public let accountID: String
  public let provider: String
  public let endpoint: String
  public let conversationID = UUID(uuidString: "DBE4C952-242D-4767-9585-A6129159AE64")!

  public init(lorvexAccountID: String?, provider: String, endpoint: String,
              providerAccountID: String?) {
    self.provider = provider
    self.endpoint = endpoint
    var input = Data("lorvex-assistant-scope-v1".utf8)
    for component in [lorvexAccountID, Optional(provider), Optional(endpoint), providerAccountID] {
      guard let component else { input.append(0); continue }
      input.append(1)
      let bytes = Data(component.utf8)
      var count = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { input.append(contentsOf: $0) }
      input.append(bytes)
    }
    accountID = "assistant-v1-" + SHA256.hash(data: input)
      .map { String(format: "%02x", $0) }.joined()
  }

  var displayNamespace: HanlinConversationNamespace {
    get throws {
      try .init(app: "lorvex", account: accountID, workspace: "personal",
                space: "assistant-display-v1")
    }
  }
}

/// Display content only. The SDK authority journal is a different record.
struct LorvexHanlinConversationSnapshot: Codable, Equatable, Sendable {
  let version: Int
  let messages: [LorvexHanlinMessage]
  let draft: String

  init(messages: [LorvexHanlinMessage], draft: String = "") {
    version = 1
    self.messages = messages
    self.draft = draft
  }

  func validate() throws {
    guard version == 1, Set(messages.map(\.id)).count == messages.count else {
      throw LorvexHanlinHistoryError.invalidSnapshot
    }
    for message in messages {
      guard Set(message.activities.map(\.id)).count == message.activities.count,
            Set(message.workspaces.map(\.id)).count == message.workspaces.count,
            message.sources.allSatisfy({
              ["https", "http"].contains($0.url.scheme ?? "") && $0.url.host != nil
            }) else { throw LorvexHanlinHistoryError.invalidSnapshot }
      var ordering = HanlinChatStructuredPartSequence()
      for part in message.structuredParts { _ = try ordering.admit(part) }
    }
  }
}

enum LorvexHanlinHistoryError: LocalizedError {
  case invalidSnapshot

  var errorDescription: String? {
    String(localized: "The saved conversation could not be read. Its existing data has been preserved.")
  }
}

/// One synchronous admission queue per display record, using the canonical store's CAS.
/// Saving never replays a tool, grants approval, or rewrites pending SDK effects.
@MainActor
final class LorvexHanlinConversationHistory {
  let scope: LorvexHanlinConversationScope
  let store: any HanlinConversationStore
  let directory: URL
  private var owner: UUID?
  /// A snapshot may advance only the revision that this owner actually loaded or saved.
  private final class WriteLease {
    let owner: UUID
    var revision: UInt64?
    init(owner: UUID, revision: UInt64?) { self.owner = owner; self.revision = revision }
  }
  private var writeLease: WriteLease?
  private var retireOwner: (@MainActor () -> _Concurrency.Task<Void, Never>)?
  private var retirement: _Concurrency.Task<Void, Never>?
  private var pendingSave: _Concurrency.Task<Void, Error>?
  private static let marker = "lorvex.assistant.display.v1"

  init(scope: LorvexHanlinConversationScope, store: any HanlinConversationStore, directory: URL) {
    self.scope = scope
    self.store = store
    self.directory = directory
  }

  func isOwned(by owner: UUID) -> Bool { self.owner == owner }

  func activate(owner: UUID,
                retire: @escaping @MainActor () -> _Concurrency.Task<Void, Never> = { _Concurrency.Task {} }) async throws
    -> LorvexHanlinConversationSnapshot? {
    // Synchronously fence the old run and admit its final display checkpoint before replacing its owner.
    let retiring = self.owner == owner ? nil : retireOwner?()
    let previousRetirement = retirement
    self.owner = owner
    retireOwner = retire
    if let retiring {
      retirement = _Concurrency.Task { @MainActor in
        if let previousRetirement { await previousRetirement.value }
        await retiring.value
      }
    }
    // Rapid A/B/C activation still waits for A's actual SDK session retirement.
    if let retirement { await retirement.value }
    if let pendingSave { _ = await pendingSave.result }
    guard self.owner == owner else { throw CancellationError() }
    let record = try await store.load(scope.conversationID, namespace: scope.displayNamespace)
    guard self.owner == owner else { throw CancellationError() }
    let snapshot = try record.map(decode)
    writeLease = WriteLease(owner: owner, revision: record?.revision)
    // Only a successful explicit reload can recover from an earlier failed save.
    pendingSave = nil
    return snapshot
  }

  func deactivate(owner: UUID) {
    guard self.owner == owner else { return }
    self.owner = nil
    retireOwner = nil
  }

  /// Old owners cannot enqueue after activation; already admitted saves finish before reopening.
  func save(_ snapshot: LorvexHanlinConversationSnapshot, owner: UUID) -> _Concurrency.Task<Void, Error> {
    guard self.owner == owner, let lease = writeLease, lease.owner == owner else {
      return _Concurrency.Task { throw CancellationError() }
    }
    let previous = pendingSave
    let store = store
    let scope = scope
    let operation = _Concurrency.Task { @MainActor in
      if let previous { try await previous.value }
      try snapshot.validate()
      let namespace = try scope.displayNamespace
      let current = try await store.load(scope.conversationID, namespace: namespace)
      if let current { _ = try self.decode(current) }
      guard current?.revision == lease.revision else { throw HanlinHostError.storeConflict }
      if let revision = lease.revision, revision == UInt64.max {
        throw HanlinHostError.storageLimitExceeded
      }
      let bytes = try JSONEncoder().encode(snapshot)
      guard let text = String(data: bytes, encoding: .utf8) else {
        throw LorvexHanlinHistoryError.invalidSnapshot
      }
      let record = HanlinConversationRecord(
        namespace: namespace, conversationID: scope.conversationID,
        revision: lease.revision.map { $0 + 1 } ?? 0,
        entries: [
          .init(runID: scope.conversationID, step: 0, sequence: 0,
                payload: .presentationReference(version: 1, opaqueReference: Self.marker)),
          .init(runID: scope.conversationID, step: 0, sequence: 1, payload: .text(text))
        ])
      try await store.save(record, replacing: lease.revision)
      lease.revision = record.revision
    }
    pendingSave = operation
    return operation
  }

  func flush() async throws { if let pendingSave { try await pendingSave.value } }

  private func decode(_ record: HanlinConversationRecord) throws -> LorvexHanlinConversationSnapshot {
    try record.validate()
    guard record.namespace == (try scope.displayNamespace),
          record.conversationID == scope.conversationID, record.entries.count == 2,
          record.entries.map(\.sequence) == [0, 1],
          record.entries.allSatisfy({ $0.runID == scope.conversationID && $0.step == 0 }),
          case .presentationReference(let version, let reference) = record.entries[0].payload,
          version == 1, reference == Self.marker,
          case .text(let text) = record.entries[1].payload,
          let bytes = text.data(using: .utf8) else { throw LorvexHanlinHistoryError.invalidSnapshot }
    let snapshot = try JSONDecoder().decode(LorvexHanlinConversationSnapshot.self, from: bytes)
    try snapshot.validate()
    return snapshot
  }
}

/// One canonical private-store actor per directory, shared with the authority journal.
@MainActor
enum LorvexHanlinConversationHistoryRegistry {
  private struct Directory {
    let store: HanlinPrivateConversationStore
    var histories: [LorvexHanlinConversationScope: LorvexHanlinConversationHistory] = [:]
  }
  private static var directories: [String: Directory] = [:]

  private static func key(_ directory: URL) -> String {
    var value = directory.standardizedFileURL.path(percentEncoded: false)
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    #if canImport(Darwin)
    for alias in ["/var", "/tmp", "/etc"]
      where value == "/private" + alias || value.hasPrefix("/private" + alias + "/") {
      value.removeFirst("/private".count)
      break
    }
    #endif
    return value
  }

  static func store(directory: URL) throws -> any HanlinConversationStore {
    let key = key(directory)
    if let entry = directories[key] { return entry.store }
    let store = try HanlinPrivateConversationStore(directory: directory)
    directories[key] = Directory(store: store)
    return store
  }

  static func history(scope: LorvexHanlinConversationScope, directory: URL) throws
    -> LorvexHanlinConversationHistory {
    let key = key(directory)
    if let existing = directories[key]?.histories[scope] { return existing }
    _ = try store(directory: directory)
    guard var entry = directories[key] else { throw LorvexHanlinHistoryError.invalidSnapshot }
    let history = LorvexHanlinConversationHistory(scope: scope, store: entry.store, directory: directory)
    entry.histories[scope] = history
    directories[key] = entry
    return history
  }
}

/// Restore only a validated card request. Rendering re-reads the existing task core.
extension LorvexHanlinTaskWorkspace: Codable {
  private enum CodingKeys: String, CodingKey { case id, presentation, rootTaskID, listID }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let id = try values.decode(String.self, forKey: .id)
    let presentation = try values.decode(String.self, forKey: .presentation)
    let rootTaskID = try values.decodeIfPresent(String.self, forKey: .rootTaskID)
    let listID = try values.decodeIfPresent(String.self, forKey: .listID)
    var payload = ["presentation": presentation]
    payload["rootTaskID"] = rootTaskID
    payload["listID"] = listID
    let bytes = try JSONEncoder().encode(payload)
    guard !id.isEmpty, let value = Self(callID: id, resultJSON: String(decoding: bytes, as: UTF8.self)) else {
      throw LorvexHanlinHistoryError.invalidSnapshot
    }
    self = value
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(presentation, forKey: .presentation)
    try values.encodeIfPresent(rootTaskID, forKey: .rootTaskID)
    try values.encodeIfPresent(listID, forKey: .listID)
  }
}
