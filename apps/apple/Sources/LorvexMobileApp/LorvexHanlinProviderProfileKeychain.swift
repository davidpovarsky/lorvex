import CryptoKit
import Foundation
import Security

/// Stable API-provider profile IDs. Fingerprints stay beside the credential in Keychain;
/// history stores only the opaque profile ID. ChatGPT uses its validated client ID instead.
@MainActor
enum LorvexHanlinProviderProfileKeychain {
  static func profileID(provider: String, endpoint: String, credential: String) throws -> String? {
    guard !credential.isEmpty else { return nil }
    var material = Data("lorvex-provider-profile-v1".utf8)
    for value in [provider, endpoint, credential] {
      let bytes = Data(value.utf8)
      var count = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { material.append(contentsOf: $0) }
      material.append(bytes)
    }
    let fingerprint = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.itorah.lorvex.hanlin-agent",
      kSecAttrAccount as String: "provider-profile-identities-v1"
    ]
    var read = query
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &value)
    var profiles: [String: String]
    if status == errSecItemNotFound { profiles = [:] }
    else {
      guard status == errSecSuccess, let bytes = value as? Data else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
      }
      profiles = try JSONDecoder().decode([String: String].self, from: bytes)
      guard profiles.values.allSatisfy({ UUID(uuidString: $0) != nil }),
            Set(profiles.values).count == profiles.count else {
        throw CocoaError(.coderReadCorrupt)
      }
    }
    if let existing = profiles[fingerprint] { return existing }
    let identifier = UUID().uuidString
    profiles[fingerprint] = identifier
    let attributes: [String: Any] = [
      kSecValueData as String: try JSONEncoder().encode(profiles),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let result: OSStatus
    if status == errSecItemNotFound {
      result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    } else {
      result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    guard result == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
    }
    return identifier
  }
}
