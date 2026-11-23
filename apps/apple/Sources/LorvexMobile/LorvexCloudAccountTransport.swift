import Foundation
import Security
import LorvexCore
import LorvexDomain
import LorvexSync

public enum LorvexCloudAccountError: Error, LocalizedError, Sendable {
  case notSignedIn
  case differentAccount
  case sessionChanged
  case service(Int)
  case invalidResponse
  case inaccessibleKeychain
  case syncFailed

  public var errorDescription: String? {
    switch self {
    case .notSignedIn: "Sign in to your Lorvex Cloud account first"
    case .differentAccount:
      "This iPad database already belongs to another Lorvex Cloud account. Export a backup and reset this device before switching accounts."
    case .sessionChanged: "The Lorvex Cloud account changed. Sync will resume with the current account."
    case .service(let code): "Lorvex Cloud HTTP " + String(code)
    case .invalidResponse: "Lorvex Cloud returned an invalid response"
    case .inaccessibleKeychain: "Unable to store credentials in the iPad Keychain"
    case .syncFailed: "Lorvex Cloud could not finish this sync batch. Your local changes are retained."
    }
  }
}

public struct LorvexCloudAccountSession: Codable, Sendable {
  public var accountID: String
  public var email: String
  public var accessToken: String
  public var refreshToken: String
  public var expiresAt: Date

  public init(accountID: String, email: String, accessToken: String,
              refreshToken: String, expiresAt: Date) {
    self.accountID = accountID
    self.email = email
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
}

public struct LorvexCloudSyncOutcome: Sendable {
  public var received = 0
  public var sent = 0
  public var serverConflicts = 0
  public var accountID: String
  public init(accountID: String) { self.accountID = accountID }
}

/// Uses Lorvex's existing durable sync_outbox, HLC and inbound appliers.
/// CloudKit must be stopped before this transport starts: both transports
/// consume the same canonical outbox, so only one may own the database.
public actor LorvexCloudAccountTransport {
  private let core: any CloudSyncEngineStore
  private let endpoint: URL
  private let request: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let saveSession: @Sendable (LorvexCloudAccountSession) throws -> Void
  private let deleteSession: @Sendable () -> Void
  private var session: LorvexCloudAccountSession?
  private var sessionRevision: UInt64 = 0
  // Transport preconditions, not business state. A missing observation forces
  // one conflict round-trip after restart; Core still owns all merge decisions.
  private var observedServerVersions: [String: String] = [:]
  private var isRunningCycle = false
  private static let maxSyncPages = 400

  public init(core: any CloudSyncEngineStore,
              endpoint: URL = URL(string:
                "https://torah-social.tail0a6c7d.ts.net:10000/cloud")!) {
    self.core = core
    self.endpoint = endpoint
    self.session = LorvexCloudKeychain.load()
    self.saveSession = { try LorvexCloudKeychain.save($0) }
    self.deleteSession = { LorvexCloudKeychain.delete() }
    self.request = { try await URLSession.shared.data(for: $0) }
  }

  /// The production transport is exercised against a deterministic HTTP peer
  /// and credential store without using a real user's Keychain or account.
  init(core: any CloudSyncEngineStore, endpoint: URL,
       session: LorvexCloudAccountSession?,
       saveSession: @escaping @Sendable (LorvexCloudAccountSession) throws -> Void,
       deleteSession: @escaping @Sendable () -> Void,
       request: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
    self.core = core
    self.endpoint = endpoint
    self.session = session
    self.saveSession = saveSession
    self.deleteSession = deleteSession
    self.request = request
  }

  public func savedAccount() -> (id: String, email: String)? {
    guard let session else { return nil }
    return (session.accountID, session.email)
  }

  private struct AccountWire: Decodable {
    struct User: Decodable { let id: String; let email: String }
    let user: User?
    let access_token: String
    let refresh_token: String
    let expires_in: Int
  }
  private struct ChangesWire: Decodable {
    let envelopes: [SyncEnvelope]
    let cursor: Int64
    let has_more: Bool
  }
  private struct PushWire: Decodable {
    struct Outcome: Decodable {
      let status: String
      let winner: SyncEnvelope?
    }
    let results: [Outcome]
  }
  private struct PushBody: Encodable {
    let request_id: String
    let envelopes: [SyncEnvelope]
    let expected_versions: [String: String?]
  }

  private func sendRaw(
    method: String, path: String, payload: Data? = nil,
    accessToken: String? = nil
  ) async throws -> Data {
    guard endpoint.scheme == "https", endpoint.host != nil,
          let url = URL(string: endpoint.absoluteString + path) else {
      throw LorvexCloudAccountError.invalidResponse
    }
    var outgoing = URLRequest(url: url)
    outgoing.httpMethod = method
    outgoing.timeoutInterval = 25
    outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
    if let accessToken {
      outgoing.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
    }
    if let payload {
      outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
      outgoing.httpBody = payload
    }
    let (data, response) = try await request(outgoing)
    guard let response = response as? HTTPURLResponse else {
      throw LorvexCloudAccountError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw LorvexCloudAccountError.service(response.statusCode)
    }
    return data
  }

  private func save(_ value: LorvexCloudAccountSession) throws {
    try saveSession(value)
    session = value
  }

  private func requireSession(_ revision: UInt64, accountID: String? = nil) throws {
    try _Concurrency.Task.checkCancellation()
    guard sessionRevision == revision, let session,
          accountID == nil || accountID == session.accountID else {
      throw LorvexCloudAccountError.sessionChanged
    }
  }

  private func bindAccount(_ accountID: String) throws {
    if let bound = try core.cloudSyncEngineCheckpoint(.oracleCloudAccountID) {
      guard bound == accountID else { throw LorvexCloudAccountError.differentAccount }
    } else {
      // Persist BEFORE any first pull, backfill or upload. A crash or offline
      // interruption must never leave account data in an unbound database.
      try core.setCloudSyncEngineCheckpoint(.oracleCloudAccountID, value: accountID)
    }
  }

  public func signIn(email: String, password: String, register: Bool) async throws
    -> LorvexCloudAccountSession
  {
    guard !email.isEmpty, !password.isEmpty else {
      throw LorvexCloudAccountError.invalidResponse
    }
    sessionRevision &+= 1
    observedServerVersions.removeAll()
    let revision = sessionRevision
    let bytes = try JSONSerialization.data(withJSONObject: [
      "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
      "password": password
    ])
    let response = try await sendRaw(
      method: "POST", path: register ? "/v1/auth/register" : "/v1/auth/login",
      payload: bytes)
    try _Concurrency.Task.checkCancellation()
    guard revision == sessionRevision else { throw LorvexCloudAccountError.sessionChanged }
    let data = try JSONDecoder().decode(AccountWire.self, from: response)
    guard let user = data.user, !user.id.isEmpty,
          !data.access_token.isEmpty, !data.refresh_token.isEmpty, data.expires_in > 0 else {
      throw LorvexCloudAccountError.invalidResponse
    }
    try bindAccount(user.id)
    let saved = LorvexCloudAccountSession(
      accountID: user.id, email: user.email, accessToken: data.access_token,
      refreshToken: data.refresh_token,
      expiresAt: Date().addingTimeInterval(TimeInterval(data.expires_in)))
    try save(saved)
    return saved
  }

  private func authorized(revision: UInt64, forceRefresh: Bool = false) async throws
    -> LorvexCloudAccountSession
  {
    try requireSession(revision)
    guard var existing = session else { throw LorvexCloudAccountError.notSignedIn }
    if !forceRefresh, existing.expiresAt.timeIntervalSinceNow > 75 { return existing }
    let bytes = try JSONSerialization.data(withJSONObject: [
      "refresh_token": existing.refreshToken
    ])
    let data = try await sendRaw(method: "POST", path: "/v1/auth/refresh", payload: bytes)
    try requireSession(revision, accountID: existing.accountID)
    let updated = try JSONDecoder().decode(AccountWire.self, from: data)
    guard updated.user == nil || updated.user?.id == existing.accountID,
          !updated.access_token.isEmpty, !updated.refresh_token.isEmpty,
          updated.expires_in > 0 else {
      throw LorvexCloudAccountError.invalidResponse
    }
    existing.accessToken = updated.access_token
    existing.refreshToken = updated.refresh_token
    existing.expiresAt = Date().addingTimeInterval(TimeInterval(updated.expires_in))
    try save(existing)
    return existing
  }

  private func authorizedCall(
    method: String, path: String, payload: Data? = nil, revision: UInt64
  ) async throws -> Data {
    let account = try await authorized(revision: revision)
    do {
      let response = try await sendRaw(
        method: method, path: path, payload: payload, accessToken: account.accessToken)
      try requireSession(revision, accountID: account.accountID)
      return response
    } catch LorvexCloudAccountError.service(401) {
      // The server can expire a token before the device's wall clock does.
      // Refresh once; a revoked refresh token is surfaced without retry loops.
      let renewed = try await authorized(revision: revision, forceRefresh: true)
      let response = try await sendRaw(
        method: method, path: path, payload: payload, accessToken: renewed.accessToken)
      try requireSession(revision, accountID: account.accountID)
      return response
    }
  }

  public func signOut() async {
    let previous = session
    // Invalidate before awaiting the logout request. Late pull/push/refresh
    // responses from the old session cannot touch local data or credentials.
    sessionRevision &+= 1
    observedServerVersions.removeAll()
    session = nil
    deleteSession()
    if let previous {
      _ = try? await sendRaw(
        method: "POST", path: "/v1/auth/logout", accessToken: previous.accessToken)
    }
    // Keep binding, cursor and local data. Only an explicit backed-up reset
    // may detach this database from its account, including while signed out.
  }

  private func identity(_ envelope: SyncEnvelope) -> String {
    envelope.entityType.asString + ":" + envelope.entityId
  }

  private func validate(_ envelope: SyncEnvelope) throws {
    try envelope.validate().get()
    guard try SyncPayloadTransportValidation.violations(for: envelope).isEmpty else {
      throw LorvexCloudAccountError.invalidResponse
    }
  }

  private func pull(
    from original: Int64, revision: UInt64, outcome: inout LorvexCloudSyncOutcome
  ) async throws -> Int64 {
    var cursor = original
    for _ in 0..<Self.maxSyncPages {
      let data = try await authorizedCall(
        method: "GET", path: "/v1/sync/changes?cursor=" + String(cursor) + "&limit=100",
        revision: revision)
      let page = try JSONDecoder().decode(ChangesWire.self, from: data)
      guard page.cursor >= cursor, !page.has_more || page.cursor > cursor else {
        throw LorvexCloudAccountError.invalidResponse
      }
      for envelope in page.envelopes { try validate(envelope) }
      if !page.envelopes.isEmpty {
        _ = try core.applyFetchedRecords(page.envelopes, parking: [], undecodable: 0)
        outcome.received += page.envelopes.count
        for envelope in page.envelopes {
          observedServerVersions[identity(envelope)] = envelope.version.description
        }
      }
      cursor = page.cursor
      // A crash between apply and checkpoint replays the page through the
      // canonical idempotent importer; it cannot skip unapplied records.
      try core.setCloudSyncEngineCheckpoint(.oracleCloudCursor, value: String(cursor))
      if !page.has_more { return cursor }
    }
    throw LorvexCloudAccountError.syncFailed
  }

  private func resolveStale(
    _ winner: SyncEnvelope, for item: PendingOutboundEnvelope,
    reconciliation: inout OutboundReconciliationRequest
  ) throws {
    let local = item.envelope
    guard winner.entityType == local.entityType, winner.entityId == local.entityId else {
      throw LorvexCloudAccountError.invalidResponse
    }
    try validate(winner)
    observedServerVersions[identity(winner)] = winner.version.description
    if try SyncMutationSemantics.isExactSemanticReplay(local, winner) {
      reconciliation.confirmedOutboxIds.append(item.outboxId)
    } else if winner.payloadSchemaVersion > LorvexVersion.payloadSchemaVersion {
      reconciliation.deferredUnknownTypeRecords.append(RawEnvelopeFields(
        entityType: winner.entityType.asString, entityId: winner.entityId,
        operation: winner.operation.asString, version: winner.version.description,
        payloadSchemaVersion: winner.payloadSchemaVersion,
        payload: winner.payload, deviceId: winner.deviceId))
      reconciliation.failures.append(OutboundFailureRecord(
        outboxId: item.outboxId,
        error: "waiting for a build that understands a newer server record", kind: .transient))
    } else if local.entityType == .entityRedirect, winner.operation == .delete {
      reconciliation.collisions.append(OutboundCollisionRecord(
        outboxId: item.outboxId, kind: .entityRedirectDelete(serverEnvelope: winner)))
    } else if let kind = try SemanticPushConflictRouting.classify(client: local, server: winner) {
      reconciliation.collisions.append(OutboundCollisionRecord(
        outboxId: item.outboxId, kind: .semanticMerge(kind: kind, serverEnvelope: winner)))
    } else if winner.version == local.version {
      reconciliation.collisions.append(OutboundCollisionRecord(
        outboxId: item.outboxId, kind: .equalVersion(serverEnvelope: winner)))
    } else if winner.version > local.version {
      reconciliation.serverWinnerEnvelopes.append(winner)
      reconciliation.confirmedOutboxIds.append(item.outboxId)
    } else {
      throw LorvexCloudAccountError.invalidResponse
    }
  }

  private func push(revision: UInt64, outcome: inout LorvexCloudSyncOutcome) async throws {
    var after: Int64?
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = formatter.string(from: Date())
    for _ in 0..<Self.maxSyncPages {
      try requireSession(revision, accountID: outcome.accountID)
      let page = try core.pendingOutboundPage(afterOutboxId: after, now: now)
      let pending = page.envelopes.filter { $0.envelope.entityType != .aiChangelog }
      for start in stride(from: 0, to: pending.count, by: 50) {
        let batch = Array(pending[start..<min(start + 50, pending.count)])
        var expected: [String: String?] = [:]
        for item in batch {
          let key = identity(item.envelope)
          expected.updateValue(observedServerVersions[key], forKey: key)
        }
        let body = PushBody(
          request_id: "ipad-" + UUID().uuidString, envelopes: batch.map(\.envelope),
          expected_versions: expected)
        let data = try JSONEncoder().encode(body)
        let reply = try await authorizedCall(
          method: "POST", path: "/v1/sync/push", payload: data, revision: revision)
        let receipt = try JSONDecoder().decode(PushWire.self, from: reply)
        guard receipt.results.count == batch.count else {
          throw LorvexCloudAccountError.invalidResponse
        }
        var reconciliation = OutboundReconciliationRequest()
        for (item, result) in zip(batch, receipt.results) {
          switch result.status {
          case "accepted", "duplicate":
            reconciliation.confirmedOutboxIds.append(item.outboxId)
            observedServerVersions[identity(item.envelope)] = item.envelope.version.description
            outcome.sent += 1
          case "stale":
            guard let winner = result.winner else {
              throw LorvexCloudAccountError.invalidResponse
            }
            try resolveStale(winner, for: item, reconciliation: &reconciliation)
            outcome.serverConflicts += 1
          default:
            throw LorvexCloudAccountError.syncFailed
          }
        }
        _ = try core.reconcileOutbound(reconciliation)
      }
      guard let next = page.lastScannedOutboxId else { return }
      guard after == nil || next > after! else {
        throw LorvexCloudAccountError.invalidResponse
      }
      after = next
    }
    throw LorvexCloudAccountError.syncFailed
  }

  public func sync() async throws -> LorvexCloudSyncOutcome {
    guard !isRunningCycle else { throw LorvexCloudAccountError.syncFailed }
    guard session != nil else { throw LorvexCloudAccountError.notSignedIn }
    isRunningCycle = true
    defer { isRunningCycle = false }
    let revision = sessionRevision
    let current = try await authorized(revision: revision)
    try bindAccount(current.accountID)
    var report = LorvexCloudSyncOutcome(accountID: current.accountID)
    let initialized = try core.cloudSyncEngineCheckpoint(.oracleCloudInitialized) == "1"
    let refetch = try core.cloudSyncEngineCheckpoint(.refetchRequired) == "true"
    let raw = try core.cloudSyncEngineCheckpoint(.oracleCloudCursor)
    let cursor = initialized && !refetch ? (Int64(raw ?? "") ?? 0) : 0
    _ = try await pull(from: cursor, revision: revision, outcome: &report)
    if refetch { try core.setCloudSyncEngineCheckpoint(.refetchRequired, value: nil) }

    let reseed = try core.cloudSyncEngineCheckpoint(.reseedRequired) == "true"
    if !initialized || reseed {
      let backfill = try core.enqueueFullResyncBackfill()
      guard backfill.skipped == 0 else { throw LorvexCloudAccountError.syncFailed }
      try core.setCloudSyncEngineCheckpoint(.oracleCloudInitialized, value: "1")
    }
    try await push(revision: revision, outcome: &report)
    let latest = try core.cloudSyncEngineCheckpoint(.oracleCloudCursor)
    _ = try await pull(from: Int64(latest ?? "") ?? 0, revision: revision, outcome: &report)
    return report
  }
}

private enum LorvexCloudKeychain {
  static let service = "com.itorah.lorvex.cloud.account"
  static let account = "active-session"

  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }

  static func load() -> LorvexCloudAccountSession? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return try? JSONDecoder().decode(LorvexCloudAccountSession.self, from: data)
  }

  static func save(_ value: LorvexCloudAccountSession) throws {
    let data = try JSONEncoder().encode(value)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if result == errSecSuccess { return }
    guard result == errSecItemNotFound else {
      throw LorvexCloudAccountError.inaccessibleKeychain
    }
    var insertion = query
    insertion.merge(attributes) { _, new in new }
    guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
      throw LorvexCloudAccountError.inaccessibleKeychain
    }
  }

  static func delete() {
    SecItemDelete(query as CFDictionary)
  }
}
