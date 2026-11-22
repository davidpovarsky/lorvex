import Foundation
import Observation
import Security
import LorvexCore
import HanlinHostContracts
import HanlinPlatformContracts

public enum LorvexRemoteBridgeError: LocalizedError, Sendable {
  case invalidEndpoint
  case credentialUnavailable
  case server(String)
  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint: "Enter a valid HTTPS bridge URL"
    case .credentialUnavailable: "Could not save the bridge credential securely"
    case .server(let message): message
    }
  }
}

public struct LorvexRemoteCommand: Decodable, Sendable {
  public let id: String
  public let name: String
  public let argumentsJSON: String
}
private struct LorvexRemotePoll: Decodable, Sendable {
  let linked: Bool
  let commands: [LorvexRemoteCommand]
}
private struct LorvexRemotePairing: Decodable, Sendable {
  let pairingCode: String
  let expiresInSeconds: Int
  let linked: Bool
}

/// Outbound-only authenticated bridge; the server never receives or opens a
/// copy of Lorvex's private SQLite database. Read tools and confirmed writes
/// always run against the same Lorvex Core service as the normal mobile UI.
/// Requires Lorvex foregrounded on iPad for incoming tool requests.
@MainActor @Observable
public final class LorvexRemoteBridgeState {
  public var endpointText: String
  public private(set) var pairingCode: String?
  public private(set) var status = "Not connected"
  public private(set) var linked = false
  public private(set) var isPolling = false
  public private(set) var isPairing = false
  public private(set) var pendingApproval: LorvexHanlinWriteRequest?
  public private(set) var lastTool: String?

  @ObservationIgnored private let core: any LorvexCoreServicing
  @ObservationIgnored private let didWrite: @Sendable () async -> Void
  @ObservationIgnored private var host: LorvexHanlinHost?
  @ObservationIgnored private var pollTask: _Concurrency.Task<Void, Never>?
  @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private let deviceID: String

  public init(core: any LorvexCoreServicing,
              didWrite: @escaping @Sendable () async -> Void = {}) {
    self.core = core
    self.didWrite = didWrite
    // Public HTTPS origin of the user's isolated Oracle/Tailscale Funnel relay.
    // No credentials are embedded in the app; OAuth and device pairing remain
    // required before any data is accessible.
    endpointText = UserDefaults.standard.string(forKey: "lorvex.mcp.remote.endpoint")
      ?? "https://torah-social.tail0a6c7d.ts.net:10000"
    let key = "lorvex.mcp.remote.device.id"
    if let existing = UserDefaults.standard.string(forKey: key) {
      deviceID = existing
    } else {
      let generated = UUID().uuidString
      deviceID = generated
      UserDefaults.standard.set(generated, forKey: key)
    }
  }

  public func resolveApproval(_ allowed: Bool) {
    let continuation = approvalContinuation
    approvalContinuation = nil
    pendingApproval = nil
    continuation?.resume(returning: allowed)
  }

  private func awaitApproval(_ request: LorvexHanlinWriteRequest) async -> Bool {
    guard pendingApproval == nil, approvalContinuation == nil,
          !_Concurrency.Task<Never, Never>.isCancelled else { return false }
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<Bool, Never>) in
      pendingApproval = request
      approvalContinuation = continuation
    }
  }

  private func nativeHost() throws -> LorvexHanlinHost {
    if let host { return host }
    let namespace = try HanlinConversationNamespace(
      app: "lorvex", account: "mcp-device", workspace: "personal", space: "tasks")
    let context = HanlinHostContext(namespace: namespace,
      sceneID: UUID(), generation: UUID(), objectReference: "lorvex-remote")
    let built = LorvexHanlinHost(
      core: core, context: context,
      authorizeWrite: { [weak self] request in
        guard let self else { return false }
        return await self.awaitApproval(request)
      },
      didWrite: didWrite)
    host = built
    return built
  }

  private static func endpoint(_ input: String) throws -> URL {
    var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasSuffix("/") { value.removeLast() }
    if value.hasSuffix("/mcp") { value.removeLast(4) }
    guard let url = URL(string: value), url.scheme == "https",
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil else {
      throw LorvexRemoteBridgeError.invalidEndpoint
    }
    return url
  }

  private var credentials: String? {
    LorvexRemoteBridgeKeychain.read()
  }

  private func request(
    _ path: String, endpoint: URL, method: String, token: String, data: Data? = nil
  ) async throws -> Data {
    guard let url = URL(string: endpoint.absoluteString + path) else {
      throw LorvexRemoteBridgeError.invalidEndpoint
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    if let data {
      req.httpBody = data
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    req.timeoutInterval = 25
    let (result,response) = try await URLSession.shared.data(for: req)
    guard let response = response as? HTTPURLResponse else {
      throw LorvexRemoteBridgeError.server("No HTTP response")
    }
    guard (200...299).contains(response.statusCode) else {
      throw LorvexRemoteBridgeError.server(
        "Bridge HTTP " + String(response.statusCode) +
        (response.statusCode == 401 ? ". Re-pair the iPad" : ""))
    }
    return result
  }

  public func pair() async {
    guard !isPairing else { return }
    isPairing = true
    defer { isPairing = false }
    do {
      let endpoint = try Self.endpoint(endpointText)
      var secret = credentials
      if secret == nil {
        let key = try LorvexRemoteBridgeKeychain.makeRandom()
        try LorvexRemoteBridgeKeychain.save(key)
        secret = key
      }
      guard let secret else { throw LorvexRemoteBridgeError.credentialUnavailable }
      let catalog: [[String: Any]] = try LorvexHanlinToolCatalog.specs.map { spec in
        let schema = try JSONSerialization.jsonObject(with: spec.schemaJSON())
        return ["name":spec.alias,"description":spec.summary,
                "writes":spec.writes,"inputSchema":schema]
      }
      let packet = try JSONSerialization.data(withJSONObject: [
        "deviceId":deviceID,"catalog":catalog
      ],options:[.sortedKeys])
      let reply = try await request(
        "/v1/device/register",endpoint:endpoint,method:"POST",token:secret,data:packet)
      let pairing = try JSONDecoder().decode(LorvexRemotePairing.self,from:reply)
      pairingCode = pairing.pairingCode
      linked = pairing.linked
      endpointText = endpoint.absoluteString
      UserDefaults.standard.set(endpointText,forKey:"lorvex.mcp.remote.endpoint")
      status = pairing.linked ? "Linked — iPad online" :
        "Enter this code in ChatGPT connection (expires in " +
        String(pairing.expiresInSeconds/60) + " minutes)"
      startPolling()
    } catch {
      status = error.localizedDescription
    }
  }

  public func startPolling() {
    guard pollTask == nil, !endpointText.isEmpty,
          credentials != nil else { return }
    pollTask = _Concurrency.Task { [weak self] in
      guard let self else { return }
      await self.pollLoop()
    }
  }

  public func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
    isPolling = false
    resolveApproval(false)
    if status == "iPad online" { status = "Paused — reopen Lorvex" }
  }

  private func pollLoop() async {
    isPolling = true
    defer {
      isPolling = false
      pollTask = nil
    }
    while !_Concurrency.Task<Never, Never>.isCancelled {
      do {
        let endpoint = try Self.endpoint(endpointText)
        guard let token = credentials else {
          throw LorvexRemoteBridgeError.credentialUnavailable
        }
        let data = try await request(
          "/v1/device/poll?device_id=" + deviceID,
          endpoint:endpoint,method:"GET",token:token)
        let polled = try JSONDecoder().decode(LorvexRemotePoll.self,from:data)
        linked = polled.linked
        status = polled.linked ? "iPad online — ChatGPT can read tasks" :
          "iPad online — awaiting ChatGPT pairing"
        for command in polled.commands {
          if _Concurrency.Task<Never, Never>.isCancelled { break }
          let result = await perform(command)
          let reply: [String: Any] = [
            "deviceId":deviceID,"id":command.id,
            "text":result.text,"error":result.isError
          ]
          let bytes = try JSONSerialization.data(withJSONObject:reply)
          _ = try await request("/v1/device/result",endpoint:endpoint,
                                method:"POST",token:token,data:bytes)
          lastTool = command.name
        }
        try await _Concurrency.Task.sleep(for: .seconds(3))
      } catch {
        if _Concurrency.Task<Never, Never>.isCancelled { break }
        status = "Bridge temporarily unavailable: " + error.localizedDescription
        try? await _Concurrency.Task.sleep(for: .seconds(5))
      }
    }
  }

  private func perform(_ command: LorvexRemoteCommand) async -> LorvexHanlinRemoteToolResult {
    do {
      let native = try nativeHost()
      return await native.invokeRemoteTool(
        name:command.name,
        argumentsJSON:Data(command.argumentsJSON.utf8),
        remoteRequestID:command.id)
    } catch {
      return .init(text:"Remote action refused: " + error.localizedDescription,isError:true)
    }
  }

  /// Revokes all remote OAuth grants for this iPad when the relay can be reached.
  public func disconnect() async {
    stopPolling()
    guard let endpoint = try? Self.endpoint(endpointText),
          let token = credentials else { return }
    if let packet = try? JSONSerialization.data(withJSONObject: ["deviceId":deviceID]) {
      _ = try? await request("/v1/device/disconnect",
                             endpoint:endpoint,method:"POST",token:token,data:packet)
    }
    pairingCode = nil
    linked = false
    status = "Disconnected; ChatGPT tokens revoked"
  }
}

private enum LorvexRemoteBridgeKeychain {
  private static let service = "com.lorvex.apple.hanlin.remote-mcp"
  private static let account = "device-pairing-secret"

  static func makeRandom() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else {
      throw LorvexRemoteBridgeError.credentialUnavailable
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func read() -> String? {
    let query: [String: Any] = [
      kSecClass as String:kSecClassGenericPassword,
      kSecAttrService as String:service,
      kSecAttrAccount as String:account,
      kSecReturnData as String:true,
      kSecMatchLimit as String:kSecMatchLimitOne
    ]
    var value: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary,&value) == errSecSuccess,
          let bytes = value as? Data else { return nil }
    return String(data:bytes,encoding:.utf8)
  }

  static func save(_ secret: String) throws {
    let lookup: [String: Any] = [
      kSecClass as String:kSecClassGenericPassword,
      kSecAttrService as String:service,
      kSecAttrAccount as String:account
    ]
    let prior = SecItemDelete(lookup as CFDictionary)
    guard prior == errSecSuccess || prior == errSecItemNotFound else {
      throw LorvexRemoteBridgeError.credentialUnavailable
    }
    var item = lookup
    item[kSecValueData as String] = Data(secret.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else {
      throw LorvexRemoteBridgeError.credentialUnavailable
    }
  }
}
