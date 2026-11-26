import Foundation
import LorvexCore
import Testing

@testable import LorvexMobile

/// Supplemental lifecycle coverage. The original 49-test release catalog is
/// unchanged; these cases exercise the same Core SQLite/outbox and transport
/// with a gated HTTP response at the foreground-to-background boundary.
@Suite("Lorvex Cloud background sync", .serialized)
@MainActor
struct LorvexCloudBackgroundSyncTests {
  @Test(.timeLimit(.minutes(1)))
  func finalFlushJoinsCancelledForegroundPollAndDrainsSavedDraft() async throws {
    let core = try await makeSeededInMemoryCore()
    let gate = CloudAccountTestGate()
    let peer = CloudAccountTestPeer(gate: gate)
    let state = LorvexCloudAccountState(
      transport: makeCloudTransport(core: core, peer: peer),
      disableICloud: {}, didSync: {})
    state.startPolling()
    await gate.waitForEntry()
    state.stopPolling()

    // Matches the app boundary: cancel polling, durably save the last draft,
    // then flush while the old request is still returning from the network.
    let id = LorvexPreviewSeedID.agendaTask
    _ = try await core.updateTask(TaskUpdateDraft(id: id, title: "Saved before background"))
    let flush = try await startBackgroundFlush(state)
    #expect(state.isSyncing)
    #expect(state.lastSync == nil)
    #expect(await peer.envelopeCount == 0)
    await gate.open()
    await flush.value

    #expect(!state.isSyncing)
    #expect(state.lastSync != nil)
    #expect(state.lastSent > 0)
    #expect(try core.unsyncedOutboundRecordNames().isEmpty)
    let reopenedCore = try makeInMemoryCore()
    _ = try await makeCloudTransport(core: reopenedCore, peer: peer).sync()
    #expect(try await reopenedCore.loadTask(id: id).title == "Saved before background")
  }

  @Test(.timeLimit(.minutes(1)))
  func expirationReleasesBackgroundWaitWithoutLosingPendingChanges() async throws {
    let core = try await makeSeededInMemoryCore()
    let gate = CloudAccountTestGate()
    let peer = CloudAccountTestPeer(gate: gate)
    let state = LorvexCloudAccountState(
      transport: makeCloudTransport(core: core, peer: peer),
      disableICloud: {}, didSync: {})
    state.startPolling()
    await gate.waitForEntry()
    state.stopPolling()
    let flush = try await startBackgroundFlush(state)

    // The final flush must finish when iOS expires its budget even though the
    // cancelled old HTTP request has not completed. A plain continuation
    // without cancellation handling would hang at this await.
    flush.cancel()
    await flush.value
    #expect(state.isSyncing)
    #expect(state.lastSync == nil)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudCursor) == nil)
    #expect(!(try core.unsyncedOutboundRecordNames()).isEmpty)
    #expect(await peer.envelopeCount == 0)

    await gate.open()
    await state.flushBeforeSuspension()
    #expect(state.lastSync != nil)
    #expect(try core.unsyncedOutboundRecordNames().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func signOutWhileFinalFlushWaitsDoesNotUploadOrRestoreTheAccount() async throws {
    let core = try await makeSeededInMemoryCore()
    let originalIDs = Set(try await core.loadSearchIndexTasks().map(\.id))
    let gate = CloudAccountTestGate()
    let peer = CloudAccountTestPeer(gate: gate)
    let state = LorvexCloudAccountState(
      transport: makeCloudTransport(core: core, peer: peer),
      disableICloud: {}, didSync: {})
    state.startPolling()
    await gate.waitForEntry()
    state.stopPolling()
    let flush = try await startBackgroundFlush(state)

    await state.signOut()
    await gate.open()
    await flush.value

    #expect(state.accountID == nil)
    #expect(state.lastSync == nil)
    #expect(!state.isSyncing)
    #expect(await peer.envelopeCount == 0)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudCursor) == nil)
    #expect(try core.cloudSyncEngineCheckpoint(.oracleCloudAccountID) == "account-a")
    #expect(!(try core.unsyncedOutboundRecordNames()).isEmpty)
    #expect(Set(try await core.loadSearchIndexTasks().map(\.id)) == originalIDs)
  }
}

/// Resume the caller only after this main-actor task starts. The flush then
/// reaches its first suspension before the caller can release the gated HTTP
/// response, so the tests exercise the in-flight boundary without sleeps.
@MainActor
private func startBackgroundFlush(
  _ state: LorvexCloudAccountState
) async throws -> _Concurrency.Task<Void, Never> {
  var work: _Concurrency.Task<Void, Never>?
  await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
    work = _Concurrency.Task { @MainActor in
      started.resume()
      await state.flushBeforeSuspension()
    }
  }
  return try #require(work)
}
