import Foundation
import Observation
import LorvexCore

/// Main-actor state shared by Lorvex's normal UI and its Hanlin chat sheet.
@MainActor @Observable
public final class LorvexCloudAccountState {
  public private(set) var email = ""
  public private(set) var accountID: String?
  public private(set) var status = "Not signed in"
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

  public init(core: any CloudSyncEngineStore,
              disableICloud: @escaping @Sendable () async -> Void,
              didSync: @escaping @Sendable () async -> Void) {
    self.transport = LorvexCloudAccountTransport(core:core)
    self.disableICloud = disableICloud
    self.didSync = didSync
    _Concurrency.Task { [weak self] in
      guard let self else { return }
      if let current = await self.transport.savedAccount() {
        self.accountID = current.id
        self.email = current.email
        self.status = "Signed in — syncing with Lorvex Cloud"
      }
    }
  }

  public func signIn(email: String, password: String, register: Bool) async {
    guard !isSigningIn else { return }
    isSigningIn = true
    defer { isSigningIn = false }
    status = "Connecting securely…"
    do {
      await disableICloud()
      let session = try await transport.signIn(email: email, password: password,
                                               register: register)
      accountID = session.accountID
      self.email = session.email
      status = "Connected — syncing with Lorvex Cloud"
      await syncNow()
      startPolling()
    } catch {
      status = error.localizedDescription
    }
  }

  public func syncNow() async {
    guard !isSyncing else { return }
    guard accountID != nil else { return }
    isSyncing = true
    defer { isSyncing = false }
    do {
      await disableICloud()
      let result = try await transport.sync()
      lastSent = result.sent
      lastReceived = result.received
      lastConflicts = result.serverConflicts
      lastSync = Date()
      status = "Synced with Lorvex Cloud"
      await didSync()
    } catch {
      status = "Sync paused: " + error.localizedDescription
    }
  }

  public func signOut() async {
    stopPolling()
    await transport.signOut()
    email = ""
    accountID = nil
    status = "Signed out. Local tasks are unchanged."
    lastSync = nil
    lastSent = 0
    lastReceived = 0
  }

  /// Server actions never require this loop: they are committed directly
  /// to the account database. The loop only drains local changes and imports
  /// server changes while the iPad is available, including after an offline day.
  public func startPolling() {
    guard accountID != nil, pollingTask == nil else { return }
    pollingTask = _Concurrency.Task { [weak self] in
      guard let self else { return }
      await self.syncNow()
      while !_Concurrency.Task<Never, Never>.isCancelled {
        try? await _Concurrency.Task.sleep(for: .seconds(20))
        if _Concurrency.Task<Never, Never>.isCancelled { break }
        await self.syncNow()
      }
      self.pollingTask = nil
    }
  }

  public func stopPolling() {
    pollingTask?.cancel()
    pollingTask = nil
  }
}
