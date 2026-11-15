import Foundation
import Security

/// API Key 这类敏感信息放 Keychain，不进 UserDefaults。
enum Keychain {
  private static let service = "com.aicd.deepseeknative"

  static func read(_ account: String) -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    query[kSecReturnData as String] = true
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return value
  }

  static func write(_ value: String?, account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let value, !value.isEmpty {
      let data = Data(value.utf8)
      let attributes: [String: Any] = [kSecValueData as String: data]
      let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
      }
    } else {
      SecItemDelete(query as CFDictionary)
    }
  }
}
