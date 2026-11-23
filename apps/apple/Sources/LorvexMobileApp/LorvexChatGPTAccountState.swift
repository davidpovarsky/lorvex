#if canImport(UIKit)
import Foundation
import HanlinChatCore
import Network
import Observation
import SafariServices
import Security
import SwiftUI
import UIKit

/// The official OpenAI OSS plan-sharing flow is local to this iPad. It does
/// not use Lorvex's server, copy ChatGPT cookies, or collect an API key.
@MainActor @Observable
final class LorvexChatGPTAccountState {
  private(set) var status = String(localized: "Not connected")
  private(set) var email: String?
  private(set) var canUsePlan = false
  private(set) var models: [HanlinChatGPTPlanModel] = []
  private(set) var isConnecting = false
  var selectedModelID: String {
    didSet { UserDefaults.standard.set(selectedModelID,forKey:"lorvex.chatgpt.plan.model") }
  }
  private(set) var authorizationURL: URL?

  @ObservationIgnored private let client = HanlinChatGPTPlanClient()
  @ObservationIgnored private var saved: HanlinChatGPTPlanCredentials?
  @ObservationIgnored private var pending: HanlinChatGPTAuthorizationAttempt?
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private let queue = DispatchQueue(label:"lorvex.chatgpt.loopback.listener")
  @ObservationIgnored private let hostID: String
  @ObservationIgnored private var sessionGeneration = UUID()
  @ObservationIgnored private var authorizationGeneration = UUID()
  @ObservationIgnored private var flowTimeout: _Concurrency.Task<Void, Never>?

  init() {
    let key="lorvex.chatgpt.plan.host-id"
    if let existing=UserDefaults.standard.string(forKey:key),existing.hasPrefix("urn:uuid:") {
      hostID=existing
    } else {
      let generated=HanlinChatGPTPlanClient.makeHostID()
      hostID=generated
      UserDefaults.standard.set(generated,forKey:key)
    }
    selectedModelID=UserDefaults.standard.string(forKey:"lorvex.chatgpt.plan.model") ?? ""
    saved=LorvexChatGPTPlanKeychain.load()
    if let saved {
      email=saved.email
      canUsePlan=saved.canUsePlan
      status=saved.canUsePlan
        ? String(localized: "Connected to ChatGPT plan")
        : String(localized: "ChatGPT account connected; plan usage not granted")
    }
  }

  func beginSignIn() {
    guard !isConnecting else{return}
    isConnecting=true
    let flowID = UUID()
    authorizationGeneration = flowID
    flowTimeout?.cancel()
    flowTimeout = _Concurrency.Task { [weak self] in
      do { try await _Concurrency.Task<Never, Never>.sleep(for: .seconds(300)) }
      catch { return }
      guard let self, self.authorizationGeneration == flowID, self.isConnecting else { return }
      self.fail(String(localized: "ChatGPT sign-in timed out. Please try again."))
    }
    status=String(localized: "Opening secure ChatGPT sign-inâ€¦")
    let params=NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(
      host:NWEndpoint.Host("127.0.0.1"),port:.any)
    do {
      let server=try NWListener(using:params)
      listener=server
      server.stateUpdateHandler={ [weak self,weak server] newState in
        _Concurrency.Task { @MainActor [weak self,weak server] in
          guard let self,let server, self.listener === server else{return}
          switch newState {
          case .ready:
            guard let port=server.port else {
              self.fail("Loopback listener has no port")
              return
            }
            do {
              let auth=try HanlinChatGPTPlanClient.makeAttempt(
                hostID:self.hostID,loopbackPort:port.rawValue,previous:self.saved)
              self.pending=auth
              self.authorizationURL=auth.url
              self.status=String(localized: "Sign in with ChatGPT in the browser")
            }catch{self.fail(error.localizedDescription)}
          case .failed(let error):
            self.fail("Unable to start local OAuth callback: "+error.localizedDescription)
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
      server.start(queue:queue)
    }catch{
      fail(error.localizedDescription)
    }
  }

  private func handleOAuthCallback(_ url:URL) {
    guard let pending, url.path == "/auth/callback", url.host == "127.0.0.1",
          let expected = URLComponents(url: pending.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value,
          let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          query.filter({ $0.name == "state" }).count == 1,
          query.first(where: { $0.name == "state" })?.value == expected else { return }
    let flowID = authorizationGeneration
    let generation = sessionGeneration
    // Close the browser only after a callback has actually arrived.
    authorizationURL=nil
    listener?.cancel();listener=nil
    self.pending=nil
    status=String(localized: "Verifying the ChatGPT account and permissionsâ€¦")
    _Concurrency.Task { [weak self] in
      guard let self else {return}
      do {
        let credentials=try await client.exchange(callback:url,attempt:pending,
                                                   priorAccount:self.saved)
        guard self.authorizationGeneration == flowID,
              self.sessionGeneration == generation else { return }
        try LorvexChatGPTPlanKeychain.save(credentials)
        self.sessionGeneration = UUID()
        self.flowTimeout?.cancel(); self.flowTimeout = nil
        self.saved=credentials
        self.email=credentials.email
        self.canUsePlan=credentials.canUsePlan
        self.isConnecting=false
        self.status=credentials.canUsePlan
          ? String(localized: "ChatGPT plan connected")
          : String(localized: "Connected without ChatGPT plan usage permission")
        if credentials.canUsePlan {await loadModels()}
      }catch{
        guard self.authorizationGeneration == flowID,
              self.sessionGeneration == generation else { return }
        self.fail(error.localizedDescription)
      }
    }
  }

  func cancelSignIn() {
    // Do not override a successful callback's pending verification when the
    // Safari sheet dismisses itself.
    guard pending != nil || authorizationURL != nil || listener != nil else { return }
    authorizationGeneration = UUID()
    flowTimeout?.cancel(); flowTimeout = nil
    listener?.cancel();listener=nil
    pending=nil
    authorizationURL=nil
    isConnecting=false
    status=saved?.canUsePlan==true ? String(localized: "ChatGPT plan connected") : String(localized: "Sign-in cancelled")
  }

  private func fail(_ message:String) {
    authorizationGeneration = UUID()
    flowTimeout?.cancel(); flowTimeout = nil
    listener?.cancel();listener=nil
    pending=nil;authorizationURL=nil
    isConnecting=false
    status=message
  }

  private func currentCredentials() async throws -> HanlinChatGPTPlanCredentials {
    let generation = sessionGeneration
    guard var account = saved, account.canUsePlan else {
      throw HanlinChatGPTPlanError.unavailable
    }
    if account.expiresAt.timeIntervalSinceNow < 90 {
      account = try await client.refresh(account)
      guard sessionGeneration == generation else { throw CancellationError() }
      try LorvexChatGPTPlanKeychain.save(account)
      saved = account
      email = account.email
      canUsePlan = account.canUsePlan
    }
    guard account.canUsePlan else { throw HanlinChatGPTPlanError.unavailable }
    return account
  }

  func accessForInference() async throws -> (token:String,modelID:String) {
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
      status = catalog.isEmpty
        ? String(localized: "This account currently has no eligible ChatGPT models.")
        : String(localized: "ChatGPT models are ready")
    } catch is CancellationError {
      return
    } catch {
      guard generation == sessionGeneration else { return }
      models = []
      reportConnectionError(error)
    }
  }

  func reportConnectionError(_ error: Error) {
    status = String(localized: "ChatGPT connection failed: ") + error.localizedDescription
  }

  func signOut() {
    sessionGeneration = UUID()
    authorizationGeneration = UUID()
    flowTimeout?.cancel(); flowTimeout = nil
    listener?.cancel();listener=nil
    pending=nil;authorizationURL=nil
    do { try LorvexChatGPTPlanKeychain.delete() }
    catch { reportConnectionError(error); return }
    saved=nil;models=[];email=nil;canUsePlan=false;isConnecting=false
    selectedModelID=""
    status=String(localized: "Signed out of ChatGPT in Lorvex")
  }
}

private enum LorvexChatGPTPlanKeychain {
  private static let service="com.itorah.lorvex.chatgpt.plan"
  private static let account="active"
  static func load()->HanlinChatGPTPlanCredentials? {
    let query:[String:Any]=[
      kSecClass as String:kSecClassGenericPassword,
      kSecAttrService as String:service,
      kSecAttrAccount as String:account,
      kSecReturnData as String:true,
      kSecMatchLimit as String:kSecMatchLimitOne
    ]
    var result:CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,
          let bytes=result as? Data else{return nil}
    return try? JSONDecoder().decode(HanlinChatGPTPlanCredentials.self,from:bytes)
  }
  static func save(_ value:HanlinChatGPTPlanCredentials)throws {
    let content = try JSONEncoder().encode(value)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: content,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated))
    }
    let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(added))
    }
  }
  static func delete() throws {
    let query:[String:Any]=[
      kSecClass as String:kSecClassGenericPassword,
      kSecAttrService as String:service,
      kSecAttrAccount as String:account
    ]
    let result = SecItemDelete(query as CFDictionary)
    guard result == errSecSuccess || result == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
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
  func beginSignIn() {}
  func cancelSignIn() {}
  func loadModels() async {}
  func signOut() {}
  func reportConnectionError(_ error: Error) { status = error.localizedDescription }
  func accessForInference() async throws -> (token:String,modelID:String) {
    throw CocoaError(.featureUnsupported)
  }
}
#endif
