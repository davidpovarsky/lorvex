import Foundation
import LorvexCore
import LorvexDomain
import LorvexSync
import Testing
import TaskVisualizationKit

@testable import LorvexMobile

@Suite("Lorvex Cloud account sync", .serialized)
@MainActor
struct LorvexCloudAccountSyncTests {
  @Test
  func interruptedFirstSyncBindsBeforeNetworkAndRejectsAnotherAccount() async throws {
    let core = try makeInMemoryCore()
    let peer = CloudAccountTestPeer()
    await peer.setOffline(true)
    let transport = makeCloudTransport(core: core, peer: peer)
    do {
      _ = try await transport.sync()
      Issue.record("offline pull unexpectedly succeeded")
    } catch is URLError {}
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudAccountID) == "account-a")
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudInitialized) == nil)

    await transport.signOut()
    await peer.setOffline(false)
    await peer.setLoginAccount("account-b")
    do {
      _ = try await transport.signIn(email: "b@example.test", password: "test-only", register: false)
      Issue.record("account-bound data was accepted by another account")
    } catch LorvexCloudAccountError.differentAccount {}
    #expect(await transport.savedAccount() == nil)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudAccountID) == "account-a")
  }

  @Test
  func lostPushReceiptAndRestartPreserveDataWithoutDuplicates() async throws {
    let core = try await makeSeededInMemoryCore()
    let originalIDs = Set(try await core.loadSearchIndexTasks().map(\.id))
    #expect(!originalIDs.isEmpty)
    let peer = CloudAccountTestPeer()
    await peer.loseNextPushReceipt()
    let beforeRestart = makeCloudTransport(core: core, peer: peer)
    do {
      _ = try await beforeRestart.sync()
      Issue.record("lost receipt unexpectedly confirmed")
    } catch is URLError {}
    #expect(!(try core.unsyncedOutboundRecordNames()).isEmpty)

    // A new transport restores credentials and the database's durable cursor
    // and outbox; no in-memory transport state survives this boundary.
    let afterRestart = makeCloudTransport(core: core, peer: peer)
    _ = try await afterRestart.sync()
    #expect(try core.unsyncedOutboundRecordNames().isEmpty)
    #expect(Set(try await core.loadSearchIndexTasks().map(\.id)) == originalIDs)
    let serverCount = await peer.envelopeCount
    _ = try await afterRestart.sync()
    #expect(await peer.envelopeCount == serverCount)

    // A fresh client opens after server writes have already committed, with
    // no old device present, and receives the exact same canonical tasks.
    let secondCore = try makeInMemoryCore()
    let reopened = makeCloudTransport(core: secondCore, peer: peer)
    _ = try await reopened.sync()
    #expect(Set(try await secondCore.loadSearchIndexTasks().map(\.id)) == originalIDs)
    #expect(try secondCore.unsyncedOutboundRecordNames().isEmpty)
    #expect(await peer.envelopeCount == serverCount)
  }

  @Test
  func visualWorkspaceMutationsConvergeThroughCanonicalCloudSync() async throws {
    let firstCore = try makeInMemoryCore()
    let secondCore = try makeInMemoryCore()
    let firstStore = MobileStore(
      core: firstCore, defaults: UserDefaults(suiteName: "workspace-sync-first-" + UUID().uuidString)!)
    let secondStore = MobileStore(
      core: secondCore, defaults: UserDefaults(suiteName: "workspace-sync-second-" + UUID().uuidString)!)
    let firstTask = try await firstStore.createPlannedTask(TaskCreateDraft(title: "Prepare"))
    let secondTask = try await firstStore.createPlannedTask(TaskCreateDraft(title: "Deliver", notes: "Keep notes"))
    let planned = try #require(LorvexDateFormatters.ymdUTC.date(from: "2026-12-02"))
    let due = try #require(LorvexDateFormatters.ymdUTC.date(from: "2026-12-08"))
    try await firstStore.performVisualTaskAction(.addDependency(
      prerequisiteID: firstTask.id, dependentID: secondTask.id))
    try await firstStore.performVisualTaskAction(.setPlannedDate(
      taskID: secondTask.id, date: PlannedDayBridge.displayDate(forStorageDate: planned)))
    try await firstStore.performVisualTaskAction(.setDueDate(
      taskID: secondTask.id, date: PlannedDayBridge.displayDate(forStorageDate: due)))
    try await firstStore.performVisualTaskAction(.setCompleted(taskID: firstTask.id, completed: true))
    try await firstStore.performVisualTaskAction(.setCompleted(taskID: secondTask.id, completed: true))

    let peer = CloudAccountTestPeer()
    let first = makeCloudTransport(core: firstCore, peer: peer)
    let second = makeCloudTransport(core: secondCore, peer: peer)
    _ = try await first.sync()
    _ = try await second.sync()
    let received = try await secondCore.loadTask(id: secondTask.id)
    #expect(received.dependsOn == [firstTask.id])
    #expect(received.status == .completed)
    #expect(received.plannedDate == planned)
    #expect(received.dueDate == due)
    #expect(received.notes == "Keep notes")
    let snapshot = try await secondStore.loadVisualTaskWorkspace()
    #expect(Set(snapshot.tasks.map(\.id)) == Set([firstTask.id, secondTask.id]))
    #expect(snapshot.tasks.allSatisfy { $0.isCompleted })

    try await secondStore.performVisualTaskAction(.removeDependency(
      prerequisiteID: firstTask.id, dependentID: secondTask.id))
    try await secondStore.performVisualTaskAction(.setCompleted(taskID: secondTask.id, completed: false))
    _ = try await second.sync()
    _ = try await first.sync()
    let returned = try await firstStore.loadVisualTaskWorkspace()
    let task = try #require(returned.tasks.first { $0.id == secondTask.id })
    #expect(task.dependencyIDs.isEmpty)
    #expect(!task.isCompleted)
    #expect(task.isReady)
    #expect(try firstCore.unsyncedOutboundRecordNames().isEmpty)
    #expect(try secondCore.unsyncedOutboundRecordNames().isEmpty)
  }

  @Test
  func concurrentServerLifecycleAndLocalTitleUseCanonicalJoin() async throws {
    let firstCore = try await makeSeededInMemoryCore()
    let secondCore = try makeInMemoryCore()
    let peer = CloudAccountTestPeer()
    let first = makeCloudTransport(core: firstCore, peer: peer)
    let second = makeCloudTransport(core: secondCore, peer: peer)
    _ = try await first.sync()
    _ = try await second.sync()
    let id = LorvexPreviewSeedID.agendaTask
    _ = try await secondCore.completeTask(id: id)
    let serverWrite = try #require(secondCore.pendingOutboundPage(
      afterOutboxId: nil, now: "2099-01-01T00:00:00.000Z").envelopes
      .first(where: { $0.envelope.entityType == .task && $0.envelope.entityId == id })?.envelope)
    _ = try await firstCore.updateTask(TaskUpdateDraft(id: id, title: "Concurrent title preserved"))

    // The server commits after this client's pull but before its push.
    await peer.injectBeforeNextPush(serverWrite)
    _ = try await first.sync()
    #expect(await peer.staleCount > 0)
    let joined = try await firstCore.loadTask(id: id)
    #expect(joined.title == "Concurrent title preserved")
    #expect(joined.status == .completed)
    _ = try await second.sync()
    let peerTask = try await secondCore.loadTask(id: id)
    #expect(peerTask.title == joined.title)
    #expect(peerTask.status == .completed)
    #expect(try firstCore.unsyncedOutboundRecordNames().isEmpty)
    #expect(try secondCore.unsyncedOutboundRecordNames().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func logoutInvalidatesAnInflightPullBeforeItCanApplyOrCheckpoint() async throws {
    let source = try await makeSeededInMemoryCore()
    let envelope = try #require(source.pendingOutboundPage(
      afterOutboxId: nil, now: "2099-01-01T00:00:00.000Z").envelopes.first?.envelope)
    let core = try makeInMemoryCore()
    let gate = CloudAccountTestGate()
    let peer = CloudAccountTestPeer(envelopes: [envelope], gate: gate)
    let transport = makeCloudTransport(core: core, peer: peer)
    let work = _Concurrency.Task { try await transport.sync() }
    await gate.waitForEntry()
    await transport.signOut()
    await gate.open()
    do {
      _ = try await work.value
      Issue.record("old account response applied after sign out")
    } catch LorvexCloudAccountError.sessionChanged {}
    #expect(await transport.savedAccount() == nil)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudCursor) == nil)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudInitialized) == nil)
    #expect(try await core.loadSearchIndexTasks().isEmpty)
  }

  @Test
  func regressingCursorIsRejectedWithoutChangingCheckpoint() async throws {
    let core = try makeInMemoryCore()
    try core.setCloudSyncEngineCheckpoint(.oracleCloudAccountID, value: "account-a")
    try core.setCloudSyncEngineCheckpoint(.oracleCloudInitialized, value: "1")
    try core.setCloudSyncEngineCheckpoint(.oracleCloudCursor, value: "4")
    let peer = CloudAccountTestPeer()
    await peer.setCursorOverride(3)
    let transport = makeCloudTransport(core: core, peer: peer)
    do {
      _ = try await transport.sync()
      Issue.record("regressing cursor unexpectedly accepted")
    } catch LorvexCloudAccountError.invalidResponse {}
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudCursor) == "4")
  }

  @Test
  func failedBackfillIsNotMarkedInitializedAndReseedIsRetried() async throws {
    let core = try await makeSeededInMemoryCore()
    let store = CloudAccountBackfillFaultStore(core: core)
    let peer = CloudAccountTestPeer()
    let transport = makeCloudTransport(core: store, peer: peer)
    do {
      _ = try await transport.sync()
      Issue.record("partial backfill unexpectedly accepted")
    } catch LorvexCloudAccountError.syncFailed {}
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudInitialized) == nil)
    store.allowBackfill()
    _ = try await transport.sync()
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudInitialized) == "1")
    #expect(try core.unsyncedOutboundRecordNames().isEmpty)

    // Cloned/restored databases set the canonical reseed checkpoint; it must
    // be honored even after initial Oracle synchronization has completed.
    try core.setCloudSyncEngineCheckpoint(.reseedRequired, value: "true")
    let before = store.backfillCount
    _ = try await transport.sync()
    #expect(store.backfillCount == before + 1)
    #expect(try core.cloudSyncEngineCheckpoint(.reseedRequired) != "true")
  }

  @Test
  func malformedPayloadDoesNotAdvanceTheCursor() async throws {
    let source = try await makeSeededInMemoryCore()
    var envelope = try #require(source.pendingOutboundPage(
      afterOutboxId: nil, now: "2099-01-01T00:00:00.000Z").envelopes.first?.envelope)
    envelope.payload = "{}"
    let core = try makeInMemoryCore()
    let peer = CloudAccountTestPeer(envelopes: [envelope])
    let transport = makeCloudTransport(core: core, peer: peer)
    do {
      _ = try await transport.sync()
      Issue.record("invalid canonical payload unexpectedly accepted")
    } catch LorvexCloudAccountError.invalidResponse {}
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudCursor) == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func foregroundBeforeSavedAccountRestorationStillStartsSync() async throws {
    let core = try makeInMemoryCore()
    let peer = CloudAccountTestPeer()
    let gate = CloudAccountTestGate()
    let state = LorvexCloudAccountState(
      transport: makeCloudTransport(core: core, peer: peer),
      disableICloud: {}, didSync: { await gate.signal() })
    // The init's async restoration has not run on this main actor yet.
    #expect(state.accountID == nil)
    state.startPolling()
    await gate.waitForEntry()
    #expect(state.accountID == "account-a")
    #expect(state.lastSync != nil)
    state.stopPolling()
  }

  @Test
  func oracleBindingKeepsCloudKitOffThroughLogoutAndFactoryRecreation() async throws {
    let suite = "test.oracleSyncOwnership." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let core = try makeInMemoryCore()
    try core.setCloudSyncEngineCheckpoint(.oracleCloudAccountID, value: "account-a")
    let store = MobileStore(core: core, defaults: defaults)
    await store.setCloudSyncModeFromSettings(.live)
    #expect(store.cloudSyncMode == .off)
    #expect(MobileSetupPreferences(defaults: defaults).cloudSyncMode == .off)

    MobileSetupPreferences(defaults: defaults).setCloudSyncMode(.live)
    let factory = MobileStoreFactory(
      environment: ["LORVEX_CLOUD_SYNC": "live"],
      coreFactory: { _ in core },
      setupPreferencesFactory: { MobileSetupPreferences(defaults: defaults) })
    let recreated = factory.makeStore()
    #expect(recreated.cloudSyncMode == .off)
    #expect(MobileSetupPreferences(defaults: defaults).cloudSyncMode == .off)
  }

  @Test
  func unauthorizedAccessRefreshesExactlyOnceAndKeepsAccountIdentity() async throws {
    let core = try makeInMemoryCore()
    let peer = CloudAccountTestPeer()
    await peer.rejectNextAccessToken()
    _ = try await makeCloudTransport(core: core, peer: peer).sync()
    #expect(await peer.refreshCount == 1)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudAccountID) == "account-a")
  }
}

func makeCloudTransport(
  core: any CloudSyncEngineStore, peer: CloudAccountTestPeer
) -> LorvexCloudAccountTransport {
  LorvexCloudAccountTransport(
    core: core, endpoint: URL(string: "https://lorvex.example.test/cloud")!,
    session: LorvexCloudAccountSession(
      accountID: "account-a", email: "a@example.test", accessToken: "test-access",
      refreshToken: "test-refresh", expiresAt: Date().addingTimeInterval(3600)),
    saveSession: { _ in }, deleteSession: {},
    request: { try await peer.send($0) })
}

actor CloudAccountTestGate {
  private var waiting: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?
  private var entered = false

  func signal() {
    entered = true
    waiting?.resume()
    waiting = nil
  }

  func enter() async {
    signal()
    await withCheckedContinuation { release = $0 }
  }

  func waitForEntry() async {
    if entered { return }
    await withCheckedContinuation { waiting = $0 }
  }

  func open() {
    release?.resume()
    release = nil
  }
}

actor CloudAccountTestPeer {
  private var envelopes: [SyncEnvelope]
  private var gate: CloudAccountTestGate?
  private var offline = false
  private var loseReceipt = false
  private var rejectAccess = false
  private var loginAccount = "account-a"
  private var cursorOverride: Int64?
  private var injectedWrite: SyncEnvelope?
  private(set) var staleCount = 0
  private(set) var refreshCount = 0
  var envelopeCount: Int { envelopes.count }

  init(envelopes: [SyncEnvelope] = [], gate: CloudAccountTestGate? = nil) {
    self.envelopes = envelopes
    self.gate = gate
  }

  func setOffline(_ value: Bool) { offline = value }
  func setLoginAccount(_ value: String) { loginAccount = value }
  func setCursorOverride(_ value: Int64) { cursorOverride = value }
  func loseNextPushReceipt() { loseReceipt = true }
  func rejectNextAccessToken() { rejectAccess = true }
  func injectBeforeNextPush(_ envelope: SyncEnvelope) { injectedWrite = envelope }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    let path = url.path
    if path.hasSuffix("/auth/logout") { return try response([:], url: url) }
    if offline { throw URLError(.notConnectedToInternet) }
    if path.hasSuffix("/auth/login") || path.hasSuffix("/auth/refresh") {
      if path.hasSuffix("/auth/refresh") { refreshCount += 1 }
      return try response([
        "user": ["id": loginAccount, "email": loginAccount + "@example.test"],
        "access_token": "renewed-test-access", "refresh_token": "renewed-test-refresh",
        "expires_in": 3600
      ], url: url)
    }
    if rejectAccess {
      rejectAccess = false
      return try response(["error": "expired"], url: url, status: 401)
    }
    if path.hasSuffix("/sync/changes") {
      if let gate {
        // The gate controls the first HTTP response only. Subsequent requests
        // exercise a real follow-up cycle after suspension or cancellation.
        self.gate = nil
        await gate.enter()
      }
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
      let cursor = Int(query?.first(where: { $0.name == "cursor" })?.value ?? "") ?? 0
      let selected = Array(envelopes.dropFirst(cursor))
      let data = try JSONEncoder().encode(CloudTestChanges(
        envelopes: selected, cursor: cursorOverride ?? Int64(envelopes.count), has_more: false))
      return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    if path.hasSuffix("/sync/push") {
      let body = try JSONDecoder().decode(CloudTestPush.self, from: #require(request.httpBody))
      if let injectedWrite {
        envelopes.append(injectedWrite)
        self.injectedWrite = nil
      }
      var results: [CloudTestPushOutcome] = []
      for envelope in body.envelopes {
        let key = envelope.entityType.asString + ":" + envelope.entityId
        let current = envelopes.last {
          $0.entityType == envelope.entityType && $0.entityId == envelope.entityId
        }
        if let current, try SyncMutationSemantics.isExactSemanticReplay(current, envelope) {
          results.append(CloudTestPushOutcome(status: "duplicate", winner: nil))
        } else if let current,
                  (body.expected_versions[key] ?? nil) != current.version.description {
          staleCount += 1
          results.append(CloudTestPushOutcome(status: "stale", winner: current))
        } else {
          envelopes.append(envelope)
          results.append(CloudTestPushOutcome(status: "accepted", winner: nil))
        }
      }
      if loseReceipt {
        loseReceipt = false
        throw URLError(.networkConnectionLost)
      }
      let reply = try JSONEncoder().encode(CloudTestPushReply(results: results))
      return (reply, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    throw URLError(.unsupportedURL)
  }

  private func response(_ object: [String: Any], url: URL, status: Int = 200) throws
    -> (Data, URLResponse)
  {
    (try JSONSerialization.data(withJSONObject: object),
     HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}

private struct CloudTestChanges: Encodable {
  let envelopes: [SyncEnvelope]
  let cursor: Int64
  let has_more: Bool
}
private struct CloudTestPush: Decodable {
  let envelopes: [SyncEnvelope]
  let expected_versions: [String: String?]
}
private struct CloudTestPushOutcome: Encodable {
  let status: String
  let winner: SyncEnvelope?
}
private struct CloudTestPushReply: Encodable { let results: [CloudTestPushOutcome] }

/// The sole simulated store fault is a recoverable backfill skip; every
/// checkpoint, outbox and merge operation still uses Core's real SQLite.
private final class CloudAccountBackfillFaultStore: CloudSyncEngineStore, @unchecked Sendable {
  private let core: any CloudSyncEngineStore
  private let lock = NSLock()
  private var shouldFail = true
  private var count = 0
  var backfillCount: Int { lock.withLock { count } }
  init(core: any CloudSyncEngineStore) { self.core = core }
  func allowBackfill() { lock.withLock { shouldFail = false } }

  func unsyncedOutboundRecordNames() throws -> Set<String> {
    try core.unsyncedOutboundRecordNames()
  }
  func newestUnsyncedOutboundVersions() throws -> [String: Hlc] {
    try core.newestUnsyncedOutboundVersions()
  }
  func unsyncedOutboxIdsHeldByServer(_ envelopes: [SyncEnvelope]) throws -> [Int64] {
    try core.unsyncedOutboxIdsHeldByServer(envelopes)
  }
  func pendingOutboundPage(afterOutboxId: Int64?, now: String) throws -> PendingOutboundPage {
    try core.pendingOutboundPage(afterOutboxId: afterOutboxId, now: now)
  }
  func applyFetchedRecords(
    _ envelopes: [SyncEnvelope], parking raws: [RawEnvelopeFields], undecodable: Int
  ) throws -> InboundApplyReport {
    try core.applyFetchedRecords(envelopes, parking: raws, undecodable: undecodable)
  }
  func reconcileOutbound(_ request: OutboundReconciliationRequest) throws
    -> OutboundReconciliationReport
  {
    try core.reconcileOutbound(request)
  }
  func enqueueFullResyncBackfill() throws -> FullResyncBackfillReport {
    let fail = lock.withLock { count += 1; return shouldFail }
    if fail { return FullResyncBackfillReport(skipped: 1, errors: ["injected backfill failure"]) }
    return try core.enqueueFullResyncBackfill()
  }
  func cloudSyncEngineCheckpoint(_ key: CloudSyncEngineCheckpoint) throws -> String? {
    try core.cloudSyncEngineCheckpoint(key)
  }
  func setCloudSyncEngineCheckpoint(_ key: CloudSyncEngineCheckpoint, value: String?) throws {
    try core.setCloudSyncEngineCheckpoint(key, value: value)
  }
}
