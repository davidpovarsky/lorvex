import Foundation
import Observation
import LorvexCore

/// Main-actor state shared by Lorvex's normal UI and its Hanlin chat sheet.
@MainActor @Observable
public final class LorvexCloudAccountState {
  public private(set) var email = ""
  public private(set) var accountID: String?
  public private(set) var status = String(localized: "cloud.account.signed_out", defaultValue: "Not signed in", table: "CloudAccount", bundle: MobileL10n.bundle)
  public private(set) var isSigningIn = false
  public private(set) var isSyncing = false
  public private(set) var lastSync: Date?
  public private(set) var lastReceived = 0
  public private(set) var lastSent = 0
  public private(set) var lastConflicts = 0

  @ObservationIgnored private let transport: LorvexCloudAccountTransport
  @ObservationIgnored private let disableICloud: @Sendable () async -> Void
  @ObservationIgnored private let didSync: @Sendable () async -> Void
  @ObservationIgnored private var pollingTask: _Concurrency.Task<Void, Never>?
  @ObservationIgnored private var wantsPolling = false
  @ObservationIgnored private var pollingGeneration: UInt64 = 0
  @ObservationIgnored private var accountRevision: UInt64 = 0

  public convenience init(
    core: any CloudSyncEngineStore,
    disableICloud: @escaping @Sendable () async -> Void,
    didSync: @escaping @Sendable () async -> Void
  ) {
    self.init(transport: LorvexCloudAccountTransport(core: core),
              disableICloud: disableICloud, didSync: didSync)
  }

  init(
    transport: LorvexCloudAccountTransport,
    disableICloud: @escaping @Sendable () async -> Void,
    didSync: @escaping @Sendable () async -> Void
  ) {
    self.transport = transport
    self.disableICloud = disableICloud
    self.didSync = didSync
    let revision = accountRevision
    _Concurrency.Task { [weak self] in
      guard let self else { return }
      let current = await self.transport.savedAccount()
      guard revision == self.accountRevision, let current else { return }
      self.accountID = current.id
      self.email = current.email
      self.status = String(localized: "cloud.account.restored", defaultValue: "Signed in — syncing with Lorvex Cloud", table: "CloudAccount", bundle: MobileL10n.bundle)
      // The scene's first .active event can precede Keychain restoration.
      // Remember that event and start immediately once the account is ready.
      self.beginPollingIfReady()
    }
  }

  public func signIn(email: String, password: String, register: Bool) async {
    guard !isSigningIn else { return }
    accountRevision &+= 1
    let revision = accountRevision
    isSigningIn = true
    defer { isSigningIn = false }
    status = String(localized: "cloud.account.connecting", defaultValue: "Connecting securely…", table: "CloudAccount", bundle: MobileL10n.bundle)
    do {
      await disableICloud()
      guard revision == accountRevision else { return }
      let session = try await transport.signIn(email: email, password: password,
                                               register: register)
      guard revision == accountRevision else { return }
      accountID = session.accountID
      self.email = session.email
      status = String(localized: "cloud.account.connected", defaultValue: "Connected — syncing with Lorvex Cloud", table: "CloudAccount", bundle: MobileL10n.bundle)
      await syncNow()
      beginPollingIfReady()
    } catch {
      guard revision == accountRevision else { return }
      status = error.localizedDescription
    }
  }

  public func syncNow() async {
    guard !isSyncing, let accountID else { return }
    let revision = accountRevision
    isSyncing = true
    defer { isSyncing = false }
    do {
      await disableICloud()
      guard revision == accountRevision, self.accountID == accountID else { return }
      let result = try await transport.sync()
      guard revision == accountRevision, self.accountID == result.accountID else { return }
      lastSent = result.sent
      lastReceived = result.received
      lastConflicts = result.serverConflicts
      lastSync = Date()
      status = String(localized: "cloud.account.synced", defaultValue: "Synced with Lorvex Cloud", table: "CloudAccount", bundle: MobileL10n.bundle)
      await didSync()
    } catch is CancellationError {
      // Scene suspension cancels a poll; durable outbox work resumes later.
    } catch {
      guard revision == accountRevision else { return }
      status = String(localized: "cloud.account.sync_paused", defaultValue: "Sync paused: ", table: "CloudAccount", bundle: MobileL10n.bundle) + error.localizedDescription
    }
  }

  public func signOut() async {
    accountRevision &+= 1
    let revision = accountRevision
    cancelPolling()
    email = ""
    accountID = nil
    status = String(localized: "cloud.account.disconnected", defaultValue: "Signed out. Local tasks are unchanged.", table: "CloudAccount", bundle: MobileL10n.bundle)
    lastSync = nil
    lastSent = 0
    lastReceived = 0
    lastConflicts = 0
    await transport.signOut()
    guard revision == accountRevision else { return }
  }

  /// Server writes do not need this loop or an open iPad. This client drains
  /// the durable local outbox and imports server changes while foregrounded.
  public func startPolling() {
    wantsPolling = true
    beginPollingIfReady()
  }

  private func beginPollingIfReady() {
    guard wantsPolling, accountID != nil, pollingTask == nil else { return }
    pollingGeneration &+= 1
    let generation = pollingGeneration
    pollingTask = _Concurrency.Task { [weak self] in
      guard let self else { return }
      while !(_Concurrency.Task<Never, Never>.isCancelled),
            self.wantsPolling, generation == self.pollingGeneration {
        await self.syncNow()
        do {
          try await _Concurrency.Task.sleep(for: .seconds(20))
        } catch { break }
      }
      // A cancelled old loop must not clear a newer foreground loop.
      if generation == self.pollingGeneration { self.pollingTask = nil }
    }
  }

  private func cancelPolling() {
    pollingGeneration &+= 1
    pollingTask?.cancel()
    pollingTask = nil
  }

  public func stopPolling() {
    wantsPolling = false
    cancelPolling()
  }
}
