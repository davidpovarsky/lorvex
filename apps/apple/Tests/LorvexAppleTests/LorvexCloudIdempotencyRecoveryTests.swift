import Foundation
import LorvexCore
import LorvexDomain
import LorvexSync
import Testing

@testable import LorvexMobile

/// Supplemental coverage, separate from the unchanged original 49-test catalog.
/// Every database operation uses the production SQLite store and sync engine;
/// the HTTP peer supplies the server's documented receipt/history contract.
@Suite("Lorvex Cloud idempotency recovery", .serialized)
@MainActor
struct LorvexCloudIdempotencyRecoveryTests {
  @Test
  func lostReceiptReopensDiskAndReusesExactRequestBeforeSendingNewEdit() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("lorvex-receipt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("store.sqlite").path
    let peer = ReceiptRecoveryPeer(mode: .loseReceipt)
    let taskID: String
    let saved: String
    do {
      let core = SwiftLorvexCoreService(databasePath: path)
      taskID = try await core.createTask(TaskCreateDraft(title: "Before restart")).id
      try prepareRecoveryAccount(core)
      do {
        _ = try await recoveryTransport(core: core, peer: peer).sync()
        Issue.record("a lost receipt was acknowledged")
      } catch is URLError {}
      saved = try #require(core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush))
      #expect(!(try core.unsyncedOutboundRecordNames()).isEmpty)
    }

    // New Core and transport instances read the actual on-disk checkpoint.
    // A newer local edit coalesces the old outbox row before its retry.
    let reopened = SwiftLorvexCoreService(databasePath: path)
    #expect(try reopened.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) == saved)
    _ = try await reopened.updateTask(TaskUpdateDraft(id: taskID, title: "Edited after restart"))
    _ = try await recoveryTransport(core: reopened, peer: peer).sync()
    let bodies = await peer.pushBodies
    try #require(bodies.count == 3)
    #expect(bodies[0] == bodies[1])
    let first = try JSONDecoder().decode(RecoveryPushBody.self, from: bodies[0])
    let last = try JSONDecoder().decode(RecoveryPushBody.self, from: bodies[2])
    #expect(first.request_id != last.request_id)
    #expect(try reopened.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) == nil)
    #expect(try reopened.unsyncedOutboundRecordNames().isEmpty)
    #expect(try await reopened.loadTask(id: taskID).title == "Edited after restart")
    #expect(await peer.historyCount == 2)
  }

  @Test
  func partialLegacyProofKeepsEntireBatchAndNeverPostsAgainAfterRestart() async throws {
    let core = try await recoveryCore()
    let original = try recoveryPending(core)
    #expect(original.count > 1)
    let peer = ReceiptRecoveryPeer(mode: .reconcile, historyPrefix: 1)
    await expectReconciliationRequired(recoveryTransport(core: core, peer: peer))
    #expect(try recoveryPending(core).map(\.outboxId) == original.map(\.outboxId))
    let saved = try #require(core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush))
    #expect(await peer.pushBodies.count == 1)

    await expectReconciliationRequired(recoveryTransport(core: core, peer: peer))
    #expect(await peer.pushBodies.count == 1)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) == saved)
    #expect(try recoveryPending(core).map(\.outboxId) == original.map(\.outboxId))
  }

  @Test
  func completeHistoricalProofIncludesTombstoneAndSupersededTaskAcrossPages() async throws {
    let core = try makeInMemoryCore()
    let live = try await core.createTask(TaskCreateDraft(title: "Earlier task"))
    let deleted = try await core.createTask(TaskCreateDraft(title: "Deleted task"))
    try await core.deleteTask(id: deleted.id)
    try prepareRecoveryAccount(core)
    let original = try recoveryPending(core)
    #expect(original.contains { $0.envelope.operation == .delete })

    // A later canonical server edit makes the old task snapshot historical,
    // while its original upload is still the mutation the client must prove.
    let remote = try makeInMemoryCore()
    _ = try remote.applyFetchedRecords(original.map(\.envelope), parking: [], undecodable: 0)
    _ = try await remote.updateTask(TaskUpdateDraft(id: live.id, title: "Later server edit"))
    let later = try #require(recoveryPending(remote).first {
      $0.envelope.entityId == live.id
    }?.envelope)
    let peer = ReceiptRecoveryPeer(mode: .reconcile, laterHistory: [later])
    let result = try await recoveryTransport(core: core, peer: peer).sync()

    #expect(result.sent == original.count)
    #expect(await peer.pushBodies.count == 1)
    #expect(await peer.recoveryCursors == Array(0...original.count).map(Int64.init))
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) == nil)
    #expect(try core.unsyncedOutboundRecordNames().isEmpty)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudCursor) == String(original.count + 1))
    #expect(try await core.loadTask(id: live.id).title == "Later server edit")
    #expect(!(try await core.loadSearchIndexTasks()).contains { $0.id == deleted.id })
  }

  @Test
  func wireFieldMismatchesCannotProveAnUploadEvenWithEquivalentPayloadText() async throws {
    for field in RecoveryMismatch.allCases {
      let core = try await recoveryCore(title: "Caf\u{00E9}")
      let original = try recoveryPending(core)
      let peer = ReceiptRecoveryPeer(mode: .reconcile, mismatch: field)
      await expectReconciliationRequired(recoveryTransport(core: core, peer: peer))
      #expect(try recoveryPending(core).map(\.outboxId) == original.map(\.outboxId))
      #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) != nil)
      #expect(await peer.pushBodies.count == 1)
    }
  }

  @Test
  func typedConflictRemainsBlockedEvenWhenHistoryContainsEveryEnvelope() async throws {
    let core = try await recoveryCore()
    let original = try recoveryPending(core)
    let peer = ReceiptRecoveryPeer(mode: .conflict)
    for _ in 0..<2 {
      do {
        _ = try await recoveryTransport(core: core, peer: peer).sync()
        Issue.record("conflicting request was silently replaced")
      } catch LorvexCloudAccountError.idempotencyConflict {}
    }
    #expect(await peer.pushBodies.count == 1)
    #expect(await peer.recoveryCursors.isEmpty)
    #expect(try recoveryPending(core).map(\.outboxId) == original.map(\.outboxId))
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) != nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellationDuringHistoryKeepsCheckpointAndQueuedMutations() async throws {
    let core = try await recoveryCore()
    let original = try recoveryPending(core)
    let gate = CloudAccountTestGate()
    let peer = ReceiptRecoveryPeer(mode: .reconcile, gate: gate)
    let transport = recoveryTransport(core: core, peer: peer)
    let work = _Concurrency.Task { try await transport.sync() }
    await gate.waitForEntry()
    let saved = try #require(core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush))
    work.cancel()
    await gate.open()
    do {
      _ = try await work.value
      Issue.record("cancelled history scan acknowledged the batch")
    } catch is CancellationError {}
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) == saved)
    #expect(try recoveryPending(core).map(\.outboxId) == original.map(\.outboxId))

    _ = try await recoveryTransport(core: core, peer: peer).sync()
    #expect(await peer.pushBodies.count == 1)
    #expect(try core.unsyncedOutboundRecordNames().isEmpty)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func signOutDuringHistoryCannotAcknowledgeOrMoveBatchToAnotherAccount() async throws {
    let core = try await recoveryCore()
    let original = try recoveryPending(core)
    let gate = CloudAccountTestGate()
    let peer = ReceiptRecoveryPeer(mode: .reconcile, gate: gate)
    let transport = recoveryTransport(core: core, peer: peer)
    let work = _Concurrency.Task { try await transport.sync() }
    await gate.waitForEntry()
    let saved = try #require(core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush))
    await transport.signOut()
    await gate.open()
    do {
      _ = try await work.value
      Issue.record("signed-out history scan acknowledged the batch")
    } catch LorvexCloudAccountError.sessionChanged {}
    #expect(await transport.savedAccount() == nil)
    #expect(try recoveryPending(core).map(\.outboxId) == original.map(\.outboxId))
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) == saved)
    do {
      _ = try await recoveryTransport(core: core, peer: peer, accountID: "account-b").sync()
      Issue.record("the unresolved batch crossed account boundaries")
    } catch LorvexCloudAccountError.differentAccount {}
    #expect(await peer.pushBodies.count == 1)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudAccountID) == "account-a")
  }

  @Test
  func interruptedOrNonAdvancingHistoryNeverAcknowledgesPartialProof() async throws {
    for fault in [RecoveryHistoryFault.network, .nonAdvancing] {
      let core = try await recoveryCore()
      let original = try recoveryPending(core)
      let peer = ReceiptRecoveryPeer(mode: .reconcile, historyFault: fault)
      await expectReconciliationRequired(recoveryTransport(core: core, peer: peer))
      #expect(try recoveryPending(core).map(\.outboxId) == original.map(\.outboxId))
      #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudCursor) == "0")
      #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) != nil)
      #expect(await peer.pushBodies.count == 1)
    }
  }

  @Test
  func unreadablePendingCheckpointCannotBecomeANewRequest() async throws {
    let core = try await recoveryCore()
    let original = try recoveryPending(core)
    try core.setCloudSyncEngineCheckpoint(.oracleCloudPendingPush, value: "{\"formatVersion\":999}")
    let peer = ReceiptRecoveryPeer(mode: .accept)
    await expectReconciliationRequired(recoveryTransport(core: core, peer: peer))
    #expect(await peer.pushBodies.isEmpty)
    #expect(try recoveryPending(core).map(\.outboxId) == original.map(\.outboxId))
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudPendingPush) == "{\"formatVersion\":999}")
  }
}

@MainActor
private func recoveryCore(title: String = "Local task") async throws -> SwiftLorvexCoreService {
  let core = try makeInMemoryCore()
  _ = try await core.createTask(TaskCreateDraft(title: title))
  _ = try await core.createTask(TaskCreateDraft(title: "Another queued task"))
  try prepareRecoveryAccount(core)
  return core
}

private func prepareRecoveryAccount(_ core: any CloudSyncEngineStore) throws {
  try core.setCloudSyncEngineCheckpoint(.oracleCloudAccountID, value: "account-a")
  try core.setCloudSyncEngineCheckpoint(.oracleCloudInitialized, value: "1")
  try core.setCloudSyncEngineCheckpoint(.oracleCloudCursor, value: "0")
}

private func recoveryPending(_ core: any CloudSyncEngineStore) throws -> [PendingOutboundEnvelope] {
  try core.pendingOutboundPage(afterOutboxId: nil, now: "2099-01-01T00:00:00.000Z")
    .envelopes.filter { $0.envelope.entityType != .aiChangelog }
}

@MainActor
private func expectReconciliationRequired(_ transport: LorvexCloudAccountTransport) async {
  do {
    _ = try await transport.sync()
    Issue.record("unproven upload was acknowledged or silently retried")
  } catch LorvexCloudAccountError.idempotencyReconciliationRequired {
  } catch {
    Issue.record("unexpected recovery error: \(error)")
  }
}

private func recoveryTransport(
  core: any CloudSyncEngineStore, peer: ReceiptRecoveryPeer, accountID: String = "account-a"
) -> LorvexCloudAccountTransport {
  LorvexCloudAccountTransport(
    core: core, endpoint: URL(string: "https://lorvex.example.test/cloud")!,
    session: LorvexCloudAccountSession(
      accountID: accountID, email: "fixture@example.test", accessToken: "test-" + accountID,
      refreshToken: "test-refresh", expiresAt: Date().addingTimeInterval(3600)),
    saveSession: { _ in }, deleteSession: {}, request: { try await peer.send($0) })
}

private enum RecoveryMismatch: CaseIterable, Sendable {
  case entityType, entityID, operation, version, schema, payload, unicodePayload, device
}
private enum RecoveryHistoryFault: Sendable { case none, network, nonAdvancing }

private struct RecoveryPushBody: Codable, Sendable {
  let request_id: String
  let envelopes: [SyncEnvelope]
  let expected_versions: [String: String?]
}
private struct RecoveryChanges: Encodable {
  let envelopes: [SyncEnvelope]
  let cursor: Int64
  let has_more: Bool
}

/// This peer preserves immutable history and caches receipt responses by request
/// ID, rejecting a changed body. Recovery pages deliberately contain one record
/// so acknowledgement must await a complete, validated history read.
private actor ReceiptRecoveryPeer {
  enum Mode: Sendable, Equatable { case accept, loseReceipt, reconcile, conflict }
  private var mode: Mode
  private let historyPrefix: Int?
  private let mismatch: RecoveryMismatch?
  private let laterHistory: [SyncEnvelope]
  private let historyFault: RecoveryHistoryFault
  private var gate: CloudAccountTestGate?
  private var history: [SyncEnvelope] = []
  private var receipts: [String: (Data, Data)] = [:]
  private(set) var pushBodies: [Data] = []
  private(set) var recoveryCursors: [Int64] = []
  var historyCount: Int { history.count }

  init(mode: Mode, historyPrefix: Int? = nil, mismatch: RecoveryMismatch? = nil,
       laterHistory: [SyncEnvelope] = [], historyFault: RecoveryHistoryFault = .none,
       gate: CloudAccountTestGate? = nil) {
    self.mode = mode
    self.historyPrefix = historyPrefix
    self.mismatch = mismatch
    self.laterHistory = laterHistory
    self.historyFault = historyFault
    self.gate = gate
  }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    if url.path.hasSuffix("/auth/logout") { return response(Data("{}".utf8), url: url) }
    if url.path.hasSuffix("/sync/changes") {
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
      let cursor = Int64(query?.first { $0.name == "cursor" }?.value ?? "") ?? 0
      let recovery = query?.first { $0.name == "limit" }?.value == "200"
      if recovery {
        recoveryCursors.append(cursor)
        if let gate {
          self.gate = nil
          await gate.enter()
        }
        if cursor > 0 {
          switch historyFault {
          case .network: throw URLError(.networkConnectionLost)
          case .nonAdvancing:
            let data = try JSONEncoder().encode(RecoveryChanges(
              envelopes: [], cursor: cursor, has_more: true))
            return response(data, url: url)
          case .none: break
          }
        }
      }
      let start = min(Int(cursor), history.count)
      let end = recovery ? min(start + 1, history.count) : history.count
      let data = try JSONEncoder().encode(RecoveryChanges(
        envelopes: Array(history[start..<end]), cursor: Int64(end), has_more: end < history.count))
      return response(data, url: url)
    }
    if url.path.hasSuffix("/sync/push") {
      let data = try #require(request.httpBody)
      pushBodies.append(data)
      let body = try JSONDecoder().decode(RecoveryPushBody.self, from: data)
      if let prior = receipts[body.request_id] {
        if prior.0 != data { return response(Data("{\"error\":\"idempotency_conflict\"}".utf8), url: url, status: 409) }
        return response(prior.1, url: url)
      }
      switch mode {
      case .reconcile, .conflict:
        if history.isEmpty {
          history = Array(body.envelopes.prefix(historyPrefix ?? body.envelopes.count))
          if let mismatch, !history.isEmpty { history[0] = try altered(history[0], field: mismatch) }
          history += laterHistory
        }
        let code = mode == .conflict ? "idempotency_conflict" : "idempotency_reconciliation_required"
        return response(Data(("{\"error\":\"" + code + "\"}").utf8), url: url, status: 409)
      case .accept, .loseReceipt:
        history += body.envelopes
        let result = try JSONSerialization.data(withJSONObject: [
          "results": body.envelopes.map { _ in ["status": "accepted"] }
        ])
        receipts[body.request_id] = (data, result)
        if mode == .loseReceipt {
          mode = .accept
          throw URLError(.networkConnectionLost)
        }
        return response(result, url: url)
      }
    }
    throw URLError(.unsupportedURL)
  }

  private func altered(_ original: SyncEnvelope, field: RecoveryMismatch) throws -> SyncEnvelope {
    var result = original
    switch field {
    case .entityType: result.entityType = .list
    case .entityID: result.entityId = UUID().uuidString.lowercased()
    case .operation: result.operation = .delete
    case .version:
      // A different canonical HLC is not the original mutation, regardless of
      // whether a value-level comparison would consider its task unchanged.
      let parts = result.version.description.split(separator: "_").map(String.init)
      result.version = try Hlc.parseCanonical(parts[0] + "_9999_" + parts[2])
    case .schema: result.payloadSchemaVersion += 1
    case .payload: result.payload += " "
    case .unicodePayload:
      let changed = result.payload.replacingOccurrences(of: "\u{00E9}", with: "e\u{0301}")
      #expect(changed == result.payload)
      #expect(!changed.utf8.elementsEqual(result.payload.utf8))
      result.payload = changed
    case .device: result.deviceId += "-other"
    }
    return result
  }

  private func response(_ data: Data, url: URL, status: Int = 200) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                           headerFields: ["Content-Type": "application/json"])!)
  }
}
