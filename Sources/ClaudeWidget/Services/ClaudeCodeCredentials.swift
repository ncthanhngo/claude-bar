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
            case .notFound:           return "No Claude Code login found. Run `claude` in Terminal first to create the Keychain item, then switch from the widget."
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

    /// Update the Claude Code OAuth blob. Used by account switching.
    ///
    /// Intentionally update-only: if the Keychain item doesn't exist yet,
    /// throws `.notFound` instead of creating one. A widget-created item
    /// would carry an ACL listing only Claude Widget — kicking `claude`
    /// CLI off the trusted-app list and triggering a macOS password prompt
    /// on every Terminal `claude` invocation. Forcing the user to run
    /// `claude` first ensures the CLI is the original creator (its binary
    /// stays on the ACL); the widget gets added the first time it reads
    /// the item and the user picks "Always Allow".
    static func write(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch status {
        case errSecSuccess:      return
        case errSecItemNotFound: throw CredentialError.notFound
        default:                 throw CredentialError.writeFailed(status)
        }
    }
}
