import Foundation
import Security
import LorvexCore
import LorvexSync

public enum LorvexCloudAccountError: Error, LocalizedError, Sendable {
  case notSignedIn
  case differentAccount
  case service(Int)
  case invalidResponse
  case inaccessibleKeychain
  case syncFailed

  public var errorDescription: String? {
    switch self {
    case .notSignedIn: "Sign in to your Lorvex Cloud account first"
    case .differentAccount:
      "This iPad database already belongs to another Lorvex Cloud account. Export a backup and reset this device before switching accounts."
    case .service(let code): "Lorvex Cloud HTTP " + String(code)
    case .invalidResponse: "Lorvex Cloud returned an invalid response"
    case .inaccessibleKeychain: "Unable to store credentials in the iPad Keychain"
    case .syncFailed: "Lorvex Cloud refused to confirm a sync batch"
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
/// This is a second *transport*, not a second task or calendar engine.
/// CloudKit must be disabled before this transport is enabled to avoid
/// two independent transports consuming the same local outbox.
public actor LorvexCloudAccountTransport {
  private let core: any CloudSyncEngineStore
  private let endpoint: URL
  private var session: LorvexCloudAccountSession?
  private var isRunningCycle = false
  private static let maxSyncPages = 400

  public init(core: any CloudSyncEngineStore,
              endpoint: URL = URL(string:
                "https://torah-social.tail0a6c7d.ts.net:10000/cloud")!) {
    self.core = core
    self.endpoint = endpoint
    self.session = LorvexCloudKeychain.load()
  }

  public func savedAccount() -> (id: String, email: String)? {
    guard let session else { return nil }
    return (session.accountID,session.email)
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
  }

  private func sendRaw(
    method: String, path: String, payload: Data? = nil,
    accessToken: String? = nil
  ) async throws -> Data {
    guard endpoint.scheme == "https", endpoint.host != nil,
          let url = URL(string: endpoint.absoluteString + path) else {
      throw LorvexCloudAccountError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 25
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let accessToken {
      request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
    }
    if let payload {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = payload
    }
    let (data,response) = try await URLSession.shared.data(for:request)
    guard let response = response as? HTTPURLResponse else {
      throw LorvexCloudAccountError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw LorvexCloudAccountError.service(response.statusCode)
    }
    return data
  }

  private func save(_ value: LorvexCloudAccountSession) throws {
    try LorvexCloudKeychain.save(value)
    session = value
  }

  public func signIn(email: String, password: String, register: Bool) async throws
    -> LorvexCloudAccountSession
  {
    guard !email.isEmpty, !password.isEmpty else {
      throw LorvexCloudAccountError.invalidResponse
    }
    let bytes = try JSONSerialization.data(withJSONObject: [
      "email": email.trimmingCharacters(in:.whitespacesAndNewlines),
      "password": password
    ])
    let response = try await sendRaw(
      method:"POST",path:register ? "/v1/auth/register" : "/v1/auth/login",
      payload:bytes)
    let data = try JSONDecoder().decode(AccountWire.self, from:response)
    guard let user=data.user else { throw LorvexCloudAccountError.invalidResponse }
    // Explicit local-account binding: never upload an existing database into
    // a different cloud account if credentials are changed on this iPad.
    if let account = try core.cloudSyncEngineCheckpoint(.oracleCloudAccountID),
       account != user.id
    {
      throw LorvexCloudAccountError.differentAccount
    }
    let saved = LorvexCloudAccountSession(
      accountID:user.id,email:user.email,accessToken:data.access_token,
      refreshToken:data.refresh_token,
      expiresAt:Date().addingTimeInterval(TimeInterval(data.expires_in)))
    try save(saved)
    return saved
  }

  private func authorized() async throws -> LorvexCloudAccountSession {
    guard var existing=session else { throw LorvexCloudAccountError.notSignedIn }
    if existing.expiresAt.timeIntervalSinceNow>75 { return existing }
    let bytes = try JSONSerialization.data(withJSONObject:[
      "refresh_token": existing.refreshToken
    ])
    let data=try await sendRaw(method:"POST",path:"/v1/auth/refresh",payload:bytes)
    let updated=try JSONDecoder().decode(AccountWire.self,from:data)
    existing.accessToken=updated.access_token
    existing.refreshToken=updated.refresh_token
    existing.expiresAt=Date().addingTimeInterval(TimeInterval(updated.expires_in))
    try save(existing)
    return existing
  }

  private func authorizedCall(method:String,path:String,payload:Data?=nil) async throws -> Data {
    let account=try await authorized()
    return try await sendRaw(method:method,path:path,payload:payload,
                             accessToken:account.accessToken)
  }

  public func signOut() async {
    if let current=session {
      _ = try? await sendRaw(method:"POST",path:"/v1/auth/logout",
                             accessToken:current.accessToken)
    }
    session=nil
    LorvexCloudKeychain.delete()
    // Keep account binding, cursor and local data: a later re-login to the
    // same account is safe, an accidental account switch is not.
  }

  private func pull(from original:Int64, outcome:inout LorvexCloudSyncOutcome) async throws -> Int64 {
    var cursor=original
    for _ in 0..<Self.maxSyncPages {
      let data=try await authorizedCall(
        method:"GET",path:"/v1/sync/changes?cursor=" + String(cursor) + "&limit=100")
      let page=try JSONDecoder().decode(ChangesWire.self,from:data)
      if !page.envelopes.isEmpty {
        _ = try core.applyFetchedRecords(page.envelopes,parking:[],undecodable:0)
        outcome.received += page.envelopes.count
      }
      cursor=page.cursor
      // Crash after local apply but before cursor checkpoint is safe: native
      // LorvexSync applies envelopes idempotently on replay.
      try core.setCloudSyncEngineCheckpoint(.oracleCloudCursor,value:String(cursor))
      if !page.has_more { return cursor }
    }
    throw LorvexCloudAccountError.syncFailed
  }

  private func push(outcome:inout LorvexCloudSyncOutcome) async throws {
    var after:Int64?
    let formatter=ISO8601DateFormatter()
    formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
    let now=formatter.string(from:Date())
    for _ in 0..<Self.maxSyncPages {
      let page=try core.pendingOutboundPage(afterOutboxId:after,now:now)
      let pending=page.envelopes.filter { $0.envelope.entityType != .aiChangelog }
      for start in stride(from:0,to:pending.count,by:50) {
        let batch=Array(pending[start..<min(start+50,pending.count)])
        let body=PushBody(
          request_id:"ipad-" + UUID().uuidString,
          envelopes:batch.map(\.envelope))
        let data=try JSONEncoder().encode(body)
        let reply=try await authorizedCall(
          method:"POST",path:"/v1/sync/push",payload:data)
        let receipt=try JSONDecoder().decode(PushWire.self,from:reply)
        guard receipt.results.count==batch.count else {
          throw LorvexCloudAccountError.invalidResponse
        }
        var confirmed:[Int64]=[]
        var winners:[SyncEnvelope]=[]
        for (item,result) in zip(batch,receipt.results) {
          switch result.status {
          case "accepted","duplicate":
            confirmed.append(item.outboxId)
            outcome.sent += 1
          case "stale":
            guard let winner=result.winner else {
              throw LorvexCloudAccountError.invalidResponse
            }
            winners.append(winner)
            confirmed.append(item.outboxId)
            outcome.serverConflicts += 1
          default: throw LorvexCloudAccountError.syncFailed
          }
        }
        _ = try core.reconcileOutbound(OutboundReconciliationRequest(
          serverWinnerEnvelopes:winners,confirmedOutboxIds:confirmed))
      }
      guard let next=page.lastScannedOutboxId else { return }
      if after==next { return }
      after=next
    }
    throw LorvexCloudAccountError.syncFailed
  }

  public func sync() async throws -> LorvexCloudSyncOutcome {
    if isRunningCycle { throw LorvexCloudAccountError.syncFailed }
    isRunningCycle=true
    defer { isRunningCycle=false }
    let current=try await authorized()
    if let bound=try core.cloudSyncEngineCheckpoint(.oracleCloudAccountID),
       bound != current.accountID
    { throw LorvexCloudAccountError.differentAccount }
    var report=LorvexCloudSyncOutcome(accountID:current.accountID)
    let initialized=try core.cloudSyncEngineCheckpoint(.oracleCloudInitialized)
    if initialized != "1" {
      // Always fetch before migrating the existing local database. Never
      // clear or silently replace any local tasks; native LWW handles joins.
      _ = try await pull(from:0,outcome:&report)
      _ = try core.enqueueFullResyncBackfill()
      try core.setCloudSyncEngineCheckpoint(.oracleCloudAccountID,
                                            value:current.accountID)
      try core.setCloudSyncEngineCheckpoint(.oracleCloudInitialized,value:"1")
    } else {
      let raw=try core.cloudSyncEngineCheckpoint(.oracleCloudCursor)
      _ = try await pull(from:Int64(raw ?? "") ?? 0,outcome:&report)
    }
    try await push(outcome:&report)
    let raw=try core.cloudSyncEngineCheckpoint(.oracleCloudCursor)
    _ = try await pull(from:Int64(raw ?? "") ?? 0,outcome:&report)
    return report
  }
}

private enum LorvexCloudKeychain {
  static let service="com.itorah.lorvex.cloud.account"
  static let account="active-session"
  static func load() -> LorvexCloudAccountSession? {
    let query:[String:Any]=[
      kSecClass as String:kSecClassGenericPassword,
      kSecAttrService as String:service,
      kSecAttrAccount as String:account,
      kSecReturnData as String:true,
      kSecMatchLimit as String:kSecMatchLimitOne
    ]
    var result:CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,
      let data=result as? Data else {return nil}
    return try? JSONDecoder().decode(LorvexCloudAccountSession.self,from:data)
  }
  static func save(_ value:LorvexCloudAccountSession) throws {
    let data=try JSONEncoder().encode(value)
    delete()
    let query:[String:Any]=[
      kSecClass as String:kSecClassGenericPassword,
      kSecAttrService as String:service,
      kSecAttrAccount as String:account,
      kSecValueData as String:data,
      kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    guard SecItemAdd(query as CFDictionary,nil)==errSecSuccess else {
      throw LorvexCloudAccountError.inaccessibleKeychain
    }
  }
  static func delete() {
    let q:[String:Any]=[
      kSecClass as String:kSecClassGenericPassword,
      kSecAttrService as String:service,
      kSecAttrAccount as String:account
    ]
    SecItemDelete(q as CFDictionary)
  }
}
