#if canImport(UIKit)
import Foundation
import HanlinChatCore
import Network
import Observation
import SafariServices
import Security
import SwiftUI
import UIKit

struct LorvexChatGPTSavedAccount: Codable, Identifiable, Sendable {
  var registration: HanlinChatGPTPlanRegistration
  let ordinal: Int
  var modelID: String
  var id: String { registration.clientID }
  var label: String { String(localized: "Account") + " " + String(ordinal) }
}

/// The official OpenAI OSS flow keeps each validated registration and renewable
/// session separate on this iPad. Account selection takes effect after OAuth.
@MainActor @Observable
final class LorvexChatGPTAccountState {
  private(set) var status = String(localized: "Not connected")
  private(set) var email: String?
  private(set) var canUsePlan = false
  private(set) var models: [HanlinChatGPTPlanModel] = []
  private(set) var accounts: [LorvexChatGPTSavedAccount] = []
  private(set) var activeAccountID: String?
  private(set) var sessionRevision = UUID()
  private(set) var isConnecting = false
  private(set) var revokingAccountIDs: Set<String> = []
  private(set) var signOutNotice: String?
  private(set) var authorizationURL: URL?
  var selectedModelID: String {
    didSet {
      guard let index = accounts.firstIndex(where: { $0.id == activeAccountID }),
            accounts[index].modelID != selectedModelID else { return }
      accounts[index].modelID = selectedModelID
      do { try persistAccounts(accounts) }
      catch { reportConnectionError(error) }
    }
  }
  var activeAccount: LorvexChatGPTSavedAccount? {
    accounts.first { $0.id == activeAccountID }
  }

  @ObservationIgnored private let client = HanlinChatGPTPlanClient()
  @ObservationIgnored private var saved: HanlinChatGPTPlanCredentials?
  @ObservationIgnored private var pending: HanlinChatGPTAuthorizationAttempt?
  @ObservationIgnored private var pendingPriorAccount: HanlinChatGPTPlanCredentials?
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private let queue = DispatchQueue(label: "lorvex.chatgpt.loopback.listener")
  @ObservationIgnored private let hostID: String
  @ObservationIgnored private var sessionGeneration = UUID()
  @ObservationIgnored private var authorizationGeneration = UUID()
  @ObservationIgnored private var flowTimeout: _Concurrency.Task<Void, Never>?

  private enum Keys {
    static let host = "lorvex.chatgpt.plan.host-id"
    static let accounts = "lorvex.chatgpt.plan.registrations"
    static let active = "lorvex.chatgpt.plan.active-client-id"
    static let legacyRegistration = "lorvex.chatgpt.plan.registration"
    static let legacyModel = "lorvex.chatgpt.plan.model"
    static let migrated = "lorvex.chatgpt.plan.multi-account-migrated"
  }

  init() {
    let defaults = UserDefaults.standard
    if let existing = defaults.string(forKey: Keys.host), existing.hasPrefix("urn:uuid:") {
      hostID = existing
    } else {
      let generated = HanlinChatGPTPlanClient.makeHostID()
      hostID = generated
      defaults.set(generated, forKey: Keys.host)
    }
    selectedModelID = ""
    do {
      if let data = defaults.data(forKey: Keys.accounts) {
        accounts = try JSONDecoder().decode([LorvexChatGPTSavedAccount].self, from: data)
        guard Set(accounts.map(\.id)).count == accounts.count,
              Set(accounts.map(\.ordinal)).count == accounts.count,
              accounts.allSatisfy({ $0.ordinal > 0 && !$0.registration.subject.isEmpty
                && !$0.id.isEmpty && $0.id != "dynamic_agent_client" }) else {
          throw HanlinChatGPTPlanError.invalidIdentity
        }
      }
      if !defaults.bool(forKey: Keys.migrated) {
        try migrateSingleAccount()
      } else {
        // A failed cleanup never reactivates or overwrites an older token set.
        try LorvexChatGPTPlanKeychain.deleteLegacy()
      }
      if let activeID = defaults.string(forKey: Keys.active),
         let profile = accounts.first(where: { $0.id == activeID }),
         let credentials = try LorvexChatGPTPlanKeychain.load(clientID: activeID) {
        guard credentials.subject == profile.registration.subject else {
          throw HanlinChatGPTPlanError.invalidIdentity
        }
        activeAccountID = activeID
        saved = credentials
        email = credentials.email
        canUsePlan = credentials.canUsePlan
        selectedModelID = profile.modelID
        status = credentials.canUsePlan
          ? String(localized: "Connected to ChatGPT plan")
          : String(localized: "ChatGPT account connected; plan usage not granted")
      }
    } catch {
      reportConnectionError(error)
    }
  }

  private func migrateSingleAccount() throws {
    let defaults = UserDefaults.standard
    if let data = defaults.data(forKey: Keys.legacyRegistration) {
      let registration = try JSONDecoder().decode(HanlinChatGPTPlanRegistration.self, from: data)
      if !accounts.contains(where: { $0.id == registration.clientID }) {
        accounts.append(.init(registration: registration, ordinal: nextOrdinal, modelID: ""))
      }
    }
    if let legacy = try LorvexChatGPTPlanKeychain.loadLegacy() {
      let destination = try LorvexChatGPTPlanKeychain.load(clientID: legacy.clientID)
      if let destination, destination.subject != legacy.subject {
        throw HanlinChatGPTPlanError.invalidIdentity
      }
      // A crash after the durable copy must not replace a newer rotating token.
      let credentials = destination ?? legacy
      let next = try updatingAccounts(with: credentials)
      if destination == nil { try LorvexChatGPTPlanKeychain.save(credentials) }
      accounts = next
      if let index = accounts.firstIndex(where: { $0.id == credentials.clientID }),
         accounts[index].modelID.isEmpty {
        accounts[index].modelID = defaults.string(forKey: Keys.legacyModel) ?? ""
      }
      try persistAccounts(accounts)
      if defaults.string(forKey: Keys.active) == nil {
        defaults.set(credentials.clientID, forKey: Keys.active)
      }
    } else {
      try persistAccounts(accounts)
    }
    defaults.set(true, forKey: Keys.migrated)
    defaults.removeObject(forKey: Keys.legacyRegistration)
    defaults.removeObject(forKey: Keys.legacyModel)
    // Only remove the old Keychain record after its per-client copy succeeded.
    try LorvexChatGPTPlanKeychain.deleteLegacy()
  }

  private var nextOrdinal: Int { (accounts.map(\.ordinal).max() ?? 0) + 1 }

  private func updatingAccounts(
    with credentials: HanlinChatGPTPlanCredentials
  ) throws -> [LorvexChatGPTSavedAccount] {
    var result = accounts
    let registration = HanlinChatGPTPlanRegistration(credentials: credentials)
    if let index = result.firstIndex(where: { $0.id == registration.clientID }) {
      guard result[index].registration.subject == registration.subject else {
        throw HanlinChatGPTPlanError.invalidIdentity
      }
      result[index].registration = registration
    } else {
      result.append(.init(registration: registration, ordinal: nextOrdinal, modelID: ""))
    }
    return result
  }

  private func persistAccounts(_ values: [LorvexChatGPTSavedAccount]) throws {
    let data = try JSONEncoder().encode(values)
    UserDefaults.standard.set(data, forKey: Keys.accounts)
  }

  /// A nil account ID explicitly registers a different ChatGPT account.
  func beginSignIn(accountID: String? = nil) {
    guard !isConnecting else { return }
    let profile = accounts.first { $0.id == accountID }
    guard accountID == nil || profile != nil else { return }
    guard accountID.map({ !revokingAccountIDs.contains($0) }) ?? true else { return }
    let prior: HanlinChatGPTPlanCredentials?
    do {
      prior = try profile.flatMap { try LorvexChatGPTPlanKeychain.load(clientID: $0.id) }
      if let prior, let profile, prior.subject != profile.registration.subject {
        throw HanlinChatGPTPlanError.invalidIdentity
      }
    } catch { reportConnectionError(error); return }
    pendingPriorAccount = prior
    isConnecting = true
    let flowID = UUID()
    authorizationGeneration = flowID
    flowTimeout?.cancel()
    flowTimeout = _Concurrency.Task { [weak self] in
      do { try await _Concurrency.Task<Never, Never>.sleep(for: .seconds(300)) }
      catch { return }
      guard let self, self.authorizationGeneration == flowID, self.isConnecting else { return }
      self.fail(String(localized: "ChatGPT sign-in timed out. Please try again."))
    }
    status = String(localized: "Opening secure ChatGPT sign-in…")
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
    do {
      let server = try NWListener(using: params)
      listener = server
      server.stateUpdateHandler = { [weak self, weak server] newState in
        _Concurrency.Task { @MainActor [weak self, weak server] in
          guard let self, let server, self.listener === server,
                self.authorizationGeneration == flowID else { return }
          switch newState {
          case .ready:
            guard let port = server.port else {
              self.fail(String(localized: "Unable to start secure ChatGPT sign-in."))
              return
            }
            do {
              let auth = try HanlinChatGPTPlanClient.makeAttempt(
                hostID: self.hostID, loopbackPort: port.rawValue, previous: prior,
                appName: "Lorvex AI Planner", registration: profile?.registration)
              self.pending = auth
              self.authorizationURL = auth.url
              self.status = String(localized: "Sign in with ChatGPT in the browser")
            } catch { self.fail(error.localizedDescription) }
          case .failed(let error): self.fail(error.localizedDescription)
          default: break
          }
        }
      }
      server.newConnectionHandler = { [weak self, weak server] connection in
        guard case .hostPort(let host, _) = connection.endpoint,
              host == NWEndpoint.Host("127.0.0.1"), let server,
              let port = server.port else {
          connection.cancel()
          return
        }
        LorvexChatGPTCallbackReader(connection: connection, port: port.rawValue) { url in
          _Concurrency.Task { @MainActor [weak self, weak server] in
            guard let self, let server, self.listener === server,
                  self.authorizationGeneration == flowID else { return }
            self.handleOAuthCallback(url)
          }
        }.start()
      }
      server.start(queue: queue)
    } catch { fail(error.localizedDescription) }
  }

  private func handleOAuthCallback(_ url: URL) {
    guard let pending, url.path == "/auth/callback", url.host == "127.0.0.1",
          let expected = URLComponents(url: pending.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value,
          let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          query.filter({ $0.name == "state" }).count == 1,
          query.first(where: { $0.name == "state" })?.value == expected else { return }
    let flowID = authorizationGeneration
    let generation = sessionGeneration
    let prior = pendingPriorAccount
    authorizationURL = nil
    listener?.cancel(); listener = nil
    self.pending = nil; pendingPriorAccount = nil
    status = String(localized: "Verifying the ChatGPT account and permissions…")
    _Concurrency.Task { [weak self] in
      guard let self else { return }
      do {
        let credentials = try await client.exchange(callback: url, attempt: pending, priorAccount: prior)
        guard self.authorizationGeneration == flowID, self.sessionGeneration == generation else { return }
        let next = try updatingAccounts(with: credentials)
        try LorvexChatGPTPlanKeychain.save(credentials)
        try persistAccounts(next)
        self.accounts = next
        self.saved = credentials
        self.activeAccountID = credentials.clientID
        UserDefaults.standard.set(credentials.clientID, forKey: Keys.active)
        self.email = credentials.email
        self.canUsePlan = credentials.canUsePlan
        self.models = []
        self.selectedModelID = next.first { $0.id == credentials.clientID }?.modelID ?? ""
        self.sessionGeneration = UUID()
        self.sessionRevision = UUID()
        self.flowTimeout?.cancel(); self.flowTimeout = nil
        self.isConnecting = false
        self.status = credentials.canUsePlan
          ? String(localized: "ChatGPT plan connected")
          : String(localized: "Connected without ChatGPT plan usage permission")
        if credentials.canUsePlan { await loadModels() }
      } catch {
        guard self.authorizationGeneration == flowID, self.sessionGeneration == generation else { return }
        self.fail(error.localizedDescription)
      }
    }
  }

  func cancelSignIn() {
    // Safari dismisses itself while the validated callback is being exchanged.
    guard pending != nil || authorizationURL != nil || listener != nil else { return }
    finishAuthorization()
    status = saved?.canUsePlan == true
      ? String(localized: "ChatGPT plan connected") : String(localized: "Sign-in cancelled")
  }

  private func finishAuthorization() {
    authorizationGeneration = UUID()
    flowTimeout?.cancel(); flowTimeout = nil
    listener?.cancel(); listener = nil
    pending = nil; pendingPriorAccount = nil; authorizationURL = nil
    isConnecting = false
  }

  private func fail(_ message: String) {
    finishAuthorization()
    status = message
  }

  private func currentCredentials() async throws -> HanlinChatGPTPlanCredentials {
    let generation = sessionGeneration
    guard var account = saved, account.clientID == activeAccountID, account.canUsePlan else {
      throw HanlinChatGPTPlanError.unavailable
    }
    if account.expiresAt.timeIntervalSinceNow < 90 {
      let previous = account
      account = try await client.refresh(previous)
      guard sessionGeneration == generation, activeAccountID == account.clientID,
            account.clientID == previous.clientID, account.subject == previous.subject else {
        throw CancellationError()
      }
      let next = try updatingAccounts(with: account)
      try LorvexChatGPTPlanKeychain.save(account)
      try persistAccounts(next)
      accounts = next
      saved = account
      email = account.email
      canUsePlan = account.canUsePlan
      if !account.canUsePlan {
        models = []
        sessionRevision = UUID()
        status = String(localized: "ChatGPT account connected; plan usage not granted")
      }
    }
    guard account.canUsePlan else { throw HanlinChatGPTPlanError.unavailable }
    return account
  }

  func accessForInference() async throws -> (token: String, modelID: String) {
    let generation = sessionGeneration
    let account = try await currentCredentials()
    if models.isEmpty { await loadModels() }
    guard generation == sessionGeneration else { throw CancellationError() }
    guard models.contains(where: { $0.slug == selectedModelID }) else {
      throw HanlinChatGPTPlanError.unavailable
    }
    return (account.accessToken, selectedModelID)
  }

  func loadModels() async {
    let generation = sessionGeneration
    do {
      let current = try await currentCredentials()
      let catalog = try await client.listModels(accessToken: current.accessToken)
      guard generation == sessionGeneration else { return }
      models = catalog
      if !catalog.contains(where: { $0.slug == selectedModelID }) {
        selectedModelID = catalog.first?.slug ?? ""
      }
      if !isConnecting {
        status = catalog.isEmpty
          ? String(localized: "This account currently has no eligible ChatGPT models.")
          : String(localized: "ChatGPT models are ready")
      }
    } catch is CancellationError {
      return
    } catch {
      guard generation == sessionGeneration else { return }
      models = []
      if !isConnecting { reportConnectionError(error) }
    }
  }

  func reportConnectionError(_ error: Error) {
    status = String(localized: "ChatGPT connection failed: ") + error.localizedDescription
  }

  func signOut() {
    guard let accountToRevoke = saved, accountToRevoke.clientID == activeAccountID else { return }
    let label = activeAccount?.label ?? String(localized: "ChatGPT account")
    sessionGeneration = UUID()
    sessionRevision = UUID()
    finishAuthorization()
    UserDefaults.standard.removeObject(forKey: Keys.active)
    activeAccountID = nil
    saved = nil; models = []; email = nil; canUsePlan = false
    selectedModelID = ""
    signOutNotice = nil
    revokingAccountIDs.insert(accountToRevoke.clientID)
    status = String(localized: "Signing out of ChatGPT…")
    let generation = sessionGeneration
    let authorizationID = authorizationGeneration
    _Concurrency.Task { [weak self, client = self.client] in
      // The shared client retries with the same resolved replacement token.
      var confirmed = false
      do { try await client.revoke(accountToRevoke); confirmed = true }
      catch { confirmed = false }
      var deletionError: Error?
      do { try LorvexChatGPTPlanKeychain.delete(accountToRevoke) }
      catch { deletionError = error }
      guard let self else { return }
      self.revokingAccountIDs.remove(accountToRevoke.clientID)
      let message: String
      if let deletionError {
        message = String(localized: "Unable to remove the saved ChatGPT session: ") + deletionError.localizedDescription
      } else if confirmed {
        message = String(localized: "Signed out of ChatGPT in Lorvex")
      } else {
        message = String(localized: "Signed out locally. OpenAI session revocation could not be confirmed.")
      }
      if deletionError != nil || !confirmed { self.signOutNotice = label + ": " + message }
      if self.sessionGeneration == generation, self.authorizationGeneration == authorizationID {
        self.status = message
      }
    }
  }
}

private enum LorvexChatGPTPlanKeychain {
  private static let service = "com.itorah.lorvex.chatgpt.plan"
  private static func query(account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: account]
  }
  private static func read(account: String) throws -> HanlinChatGPTPlanCredentials? {
    var request = query(account: account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let bytes = result as? Data else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return try JSONDecoder().decode(HanlinChatGPTPlanCredentials.self, from: bytes)
  }
  static func load(clientID: String) throws -> HanlinChatGPTPlanCredentials? {
    let value = try read(account: "client:" + clientID)
    guard value == nil || value?.clientID == clientID else {
      throw HanlinChatGPTPlanError.invalidIdentity
    }
    return value
  }
  static func loadLegacy() throws -> HanlinChatGPTPlanCredentials? { try read(account: "active") }
  static func save(_ value: HanlinChatGPTPlanCredentials) throws {
    guard !value.clientID.isEmpty, value.clientID != "dynamic_agent_client", !value.subject.isEmpty else {
      throw HanlinChatGPTPlanError.invalidIdentity
    }
    if let existing = try load(clientID: value.clientID), existing.subject != value.subject {
      throw HanlinChatGPTPlanError.invalidIdentity
    }
    let content = try JSONEncoder().encode(value)
    let request = query(account: "client:" + value.clientID)
    let attributes: [String: Any] = [
      kSecValueData as String: content,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let updated = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated))
    }
    let added = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(added))
    }
  }
  static func delete(_ session: HanlinChatGPTPlanCredentials) throws {
    guard let current = try load(clientID: session.clientID),
          current.subject == session.subject,
          current.refreshToken == session.refreshToken else { return }
    // A new, validated login may have installed a different session meanwhile.
    try remove(account: "client:" + session.clientID)
  }
  static func deleteLegacy() throws { try remove(account: "active") }
  private static func remove(account: String) throws {
    let status = SecItemDelete(query(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }
}

/// Reads one bounded HTTP callback on a serial queue; no credentials are logged.
private final class LorvexChatGPTCallbackReader: @unchecked Sendable {
  private let connection: NWConnection
  private let port: UInt16
  private let callback: @Sendable (URL) -> Void
  private let queue = DispatchQueue(label: "lorvex.chatgpt.oauth.connection")
  private var buffer = Data()
  private var finished = false

  init(connection: NWConnection, port: UInt16,
       callback: @escaping @Sendable (URL) -> Void) {
    self.connection = connection; self.port = port; self.callback = callback
  }

  func start() {
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.close() }
    receive()
  }

  private func close() {
    finished = true
    connection.cancel()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
      guard !finished, error == nil, let data, !data.isEmpty else { close(); return }
      buffer.append(data)
      guard buffer.count <= 8192 else { close(); return }
      guard let request = String(data: buffer, encoding: .utf8),
            request.contains("\r\n\r\n") else {
        if complete { close() } else { receive() }
        return
      }
      let lines = request.components(separatedBy: "\r\n")
      let parts = (lines.first ?? "").split(separator: " ")
      guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
            let url = URL(string: "http://127.0.0.1:\(port)" + String(parts[1])),
            url.path == "/auth/callback",
            lines.dropFirst().contains(where: {
              $0.lowercased() == "host: 127.0.0.1:\(port)"
            }) else { close(); return }
      finished = true
      let body = "<html><meta charset=\"utf-8\"><body>Return to Lorvex AI Planner.</body></html>"
      let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
        + "Cache-Control: no-store\r\nConnection: close\r\n"
        + "Content-Security-Policy: default-src 'none'\r\n"
        + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
      connection.send(content: Data(response.utf8), completion: .contentProcessed { [self] _ in
        connection.cancel()
      })
      callback(url)
    }
  }
}

struct LorvexChatGPTPlanBrowser: UIViewControllerRepresentable {
  let url:URL
  func makeUIViewController(context:Context)->SFSafariViewController {
    let browser=SFSafariViewController(url:url)
    browser.dismissButtonStyle = .close
    return browser
  }
  func updateUIViewController(_ view:SFSafariViewController,context:Context) {}
}
#else
import Foundation
import Observation

@MainActor @Observable
final class LorvexChatGPTAccountState {
  var status = String(localized: "ChatGPT account sign-in requires the iPad application")
  var email: String?
  var canUsePlan = false
  var isConnecting = false
  var selectedModelID = ""
  var authorizationURL: URL?
  private(set) var sessionRevision = UUID()
  func beginSignIn(accountID: String? = nil) {}
  func cancelSignIn() {}
  func loadModels() async {}
  func signOut() { sessionRevision = UUID() }
  func reportConnectionError(_ error: Error) { status = error.localizedDescription }
  func accessForInference() async throws -> (token:String,modelID:String) {
    throw CocoaError(.featureUnsupported)
  }
}
#endif
