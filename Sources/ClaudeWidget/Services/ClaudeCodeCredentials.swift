import Foundation
import Security

/// Reads/writes the macOS Keychain entry Claude Code uses for OAuth.
/// service = `Claude Code-credentials`, account = current OS user.
enum ClaudeCodeCredentials {

    private static let service = "Claude Code-credentials"
    private static var account: String { NSUserName() }

    enum CredentialError: LocalizedError {
        case readFailed(OSStatus)
        case writeFailed(OSStatus)
        case notFound

        var errorDescription: String? {
            switch self {
            case .readFailed(let s):  return "Could not read Claude Code credentials (status \(s))."
            case .writeFailed(let s): return "Could not write Claude Code credentials (status \(s))."
            case .notFound:           return "No Claude Code login found. Sign in via `claude` first."
            }
        }
    }

    /// Read current Claude Code OAuth blob. Throws on missing or error.
    static func read() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let str = String(data: data, encoding: .utf8) else {
                throw CredentialError.readFailed(status)
            }
            return str
        case errSecItemNotFound: throw CredentialError.notFound
        default:                 throw CredentialError.readFailed(status)
        }
    }

    /// Upsert the Claude Code OAuth blob. Used by account switching.
    static func write(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw CredentialError.writeFailed(updateStatus)
        }
        var addAttrs = query
        addAttrs[kSecValueData as String] = data
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialError.writeFailed(addStatus)
        }
    }
}
