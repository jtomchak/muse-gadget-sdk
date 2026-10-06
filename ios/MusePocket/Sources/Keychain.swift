import CryptoKit
import Foundation
import Security

enum PocketKeychain {
  static func museAccount(_ host: String) -> String {
    "muse.voice."
      + SHA256.hash(data: Data(host.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func relayAccount(_ url: URL) -> String {
    "relay."
      + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func read(_ name: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.jtomchak.musepocket", kSecAttrAccount as String: name,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
  static func save(_ value: String, name: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.jtomchak.musepocket", kSecAttrAccount as String: name,
    ]
    let attrs: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attrs) { _, v in v } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }
  static func delete(_ name: String) {
    SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.jtomchak.musepocket", kSecAttrAccount as String: name,
      ] as CFDictionary)
  }
}
