import Foundation
import Security
import WebKit

/// Persists Claude web usage cookies by account email.
///
/// Two layers:
///   1. **Local Keychain** (this file) — non-synchronizable items in
///      login.keychain-db. Fast lookups; survives app relaunch on the same Mac.
///   2. **Encrypted iCloud Drive bundle** ([[WebCookieCloudSync]]) — pushed
///      alongside the accounts `cloud-bundle.enc` when the user has configured
///      the cloud-sync passphrase. Provides cross-device sync.
///
/// History: an earlier version used `kSecAttrSynchronizable: true` to ride
/// iCloud Keychain. That path silently fails with `errSecMissingEntitlement`
/// because the app is ad-hoc-signed (no iCloud entitlement available without
/// an Apple Developer Program identity). Dropping the flag makes local
/// persistence actually work; cross-device sync moves to the bundle layer.
@MainActor
enum ClaudeWebSessionSync {
    private static let service = "claude-bar-web-usage-session"

    static func hasSession(for account: AccountDTO) -> Bool {
        if loadLocal(for: account) != nil { return true }
        return WebCookieCloudSync.hasSession(for: account)
    }

    static func save(account: AccountDTO, dataStore: WKWebsiteDataStore) async {
        let cookies = await dataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("claude.ai") }
            .map(SyncedCookie.init)
        guard !cookies.isEmpty,
              let data = try? JSONEncoder().encode(SyncedSession(cookies: cookies)) else {
            return
        }
        saveLocal(account: account, data: data)
        await WebCookieCloudSync.save(account: account, dataStore: dataStore)
    }

    static func restore(account: AccountDTO, dataStore: WKWebsiteDataStore) async -> Bool {
        if let session = loadLocal(for: account) {
            return await apply(session: session, to: dataStore)
        }
        let restored = await WebCookieCloudSync.restore(account: account, dataStore: dataStore)
        if restored {
            // Warm the local cache so subsequent restores skip the encrypt/decrypt.
            await save(account: account, dataStore: dataStore)
        }
        return restored
    }

    static func remove(account: AccountDTO) {
        SecItemDelete(itemQuery(for: account) as CFDictionary)
        WebCookieCloudSync.remove(account: account)
    }

    // MARK: - Local Keychain

    private static func saveLocal(account: AccountDTO, data: Data) {
        let query = itemQuery(for: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[ClaudeWebSessionSync] SecItemAdd failed (status=\(addStatus)) for \(account.email)")
            }
        } else if updateStatus != errSecSuccess {
            NSLog("[ClaudeWebSessionSync] SecItemUpdate failed (status=\(updateStatus)) for \(account.email)")
        }
    }

    private static func loadLocal(for account: AccountDTO) -> SyncedSession? {
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

    private static func apply(session: SyncedSession, to dataStore: WKWebsiteDataStore) async -> Bool {
        var restored = false
        for cookie in session.cookies.compactMap(\.httpCookie) {
            await dataStore.httpCookieStore.setCookie(cookie)
            restored = true
        }
        return restored
    }

    private static func itemQuery(for account: AccountDTO) -> [CFString: Any] {
        // No `kSecAttrSynchronizable` here — iCloud Keychain sync requires an
        // entitlement that ad-hoc-signed builds don't carry. Cross-device sync
        // happens through [[WebCookieCloudSync]] instead.
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: syncAccount(for: account)
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
