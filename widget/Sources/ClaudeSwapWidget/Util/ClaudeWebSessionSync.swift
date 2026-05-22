import Foundation
import Security
import WebKit

/// Syncs Claude web usage cookies by account email through iCloud Keychain.
///
/// WKWebsiteDataStore profile identifiers stay local to each Mac. A synced
/// cookie payload lets another Mac recreate its own profile for the same email.
@MainActor
enum ClaudeWebSessionSync {
    private static let service = "claude-bar-web-usage-session"

    static func hasSession(for account: AccountDTO) -> Bool {
        load(for: account) != nil
    }

    static func save(account: AccountDTO, dataStore: WKWebsiteDataStore) async {
        let cookies = await dataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("claude.ai") }
            .map(SyncedCookie.init)
        guard !cookies.isEmpty,
              let data = try? JSONEncoder().encode(SyncedSession(cookies: cookies)) else {
            return
        }

        let query = itemQuery(for: account)
        let update: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func restore(account: AccountDTO, dataStore: WKWebsiteDataStore) async -> Bool {
        guard let session = load(for: account) else { return false }
        var restored = false
        for cookie in session.cookies.compactMap(\.httpCookie) {
            await dataStore.httpCookieStore.setCookie(cookie)
            restored = true
        }
        return restored
    }

    static func remove(account: AccountDTO) {
        SecItemDelete(itemQuery(for: account) as CFDictionary)
    }

    private static func load(for account: AccountDTO) -> SyncedSession? {
        var query = itemQuery(for: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip

        var ref: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(SyncedSession.self, from: data)
    }

    private static func itemQuery(for account: AccountDTO) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: syncAccount(for: account),
            kSecAttrSynchronizable: true
        ]
    }

    private static func syncAccount(for account: AccountDTO) -> String {
        account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct SyncedSession: Codable {
        let version: Int = 1
        let cookies: [SyncedCookie]

        enum CodingKeys: String, CodingKey {
            case version
            case cookies
        }
    }

    private struct SyncedCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresDate: Date?
        let isSecure: Bool

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expiresDate = cookie.expiresDate
            isSecure = cookie.isSecure
        }

        var httpCookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path
            ]
            if let expiresDate {
                properties[.expires] = expiresDate
            }
            if isSecure {
                properties[.secure] = "TRUE"
            }
            return HTTPCookie(properties: properties)
        }
    }
}
