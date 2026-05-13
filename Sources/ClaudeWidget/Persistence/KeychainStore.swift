import Foundation
import Security

/// Thin CRUD wrapper around macOS Keychain Services.
///
/// Each `KeychainStore` instance scopes to a single `service` name; accounts
/// (a.k.a. keys) live under that service.
struct KeychainStore {

    let service: String

    @discardableResult
    func write(_ account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        delete(account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: - Predefined scopes

    /// Storage for the widget's own secrets (sessionKey + orgId).
    static let widget = KeychainStore(service: "ClaudeWidget-web")
}
