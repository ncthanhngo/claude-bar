import CryptoKit
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

    /// Master Keychain gate — same toggle as iCloud sync because every read
    /// here also hits a Keychain item the app didn't create with its current
    /// code signature, which is exactly the second "Allow access?" prompt
    /// users were getting after each Sparkle update. When the toggle is off,
    /// the WKWebsiteDataStore still holds its own persisted cookies on disk,
    /// so the embedded web profile survives across launches without this
    /// secondary Keychain cache.
    private static var keychainAccessAllowed: Bool {
        AppSettings.shared.iCloudSyncEnabled
    }

    static func hasSession(for account: AccountDTO) -> Bool {
        guard keychainAccessAllowed else { return false }
        if loadLocal(for: account) != nil { return true }
        return WebCookieCloudSync.hasSession(for: account)
    }

    static func save(account: AccountDTO, dataStore: WKWebsiteDataStore) async {
        guard keychainAccessAllowed else { return }
        let now = Date()
        let cookies = await dataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("claude.ai") }
            .filter { $0.expiresDate.map { $0 > now } ?? true }
            .map(SyncedCookie.init)
        guard !cookies.isEmpty else { return }

        // Idempotent guard: if the cookie set is byte-identical to what we
        // last persisted, skip writing. Cross-device sync relies on this —
        // otherwise the periodic `restore → save` echo in WebFallbackCoordinator
        // re-pushes restored-from-iCloud cookies and clobbers a fresher push
        // from the other machine.
        let newFingerprint = fingerprint(of: cookies)
        if let cached = loadLocal(for: account), cached.fingerprint == newFingerprint {
            return
        }

        let session = SyncedSession(cookies: cookies, updatedAt: now)
        guard let data = try? JSONEncoder().encode(session) else { return }
        saveLocal(account: account, data: data)
        await WebCookieCloudSync.save(account: account, dataStore: dataStore)
    }

    static func restore(account: AccountDTO, dataStore: WKWebsiteDataStore) async -> Bool {
        guard keychainAccessAllowed else { return false }
        let local = loadLocal(for: account)
        let cloud = WebCookieCloudSync.loadCookies(for: account)

        // Pick freshest. Local payloads from the v1 format have no timestamp
        // (treated as distantPast) so the cloud wins on first restore after
        // upgrade, which is the safer direction.
        let localAge = local?.updatedAt ?? .distantPast
        let cloudAge = cloud?.updatedAt ?? .distantPast

        if let cloud, cloudAge >= localAge {
            // Cloud wins: apply cloud cookies + warm local cache so subsequent
            // restores on this machine pick the same set without decrypting.
            let applied = await apply(cookies: cloud.cookies, to: dataStore)
            if applied {
                let synced = cloud.cookies.map(SyncedCookie.init)
                let session = SyncedSession(cookies: synced, updatedAt: cloud.updatedAt)
                if let data = try? JSONEncoder().encode(session) {
                    saveLocal(account: account, data: data)
                }
            }
            return applied
        }

        if let local {
            return await apply(session: local, to: dataStore)
        }
        return false
    }

    static func remove(account: AccountDTO) {
        // Delete is allowed even with the toggle off — explicit user-initiated
        // cleanup (Disconnect button) and SecItemDelete doesn't pop the ACL
        // prompt the way reads/updates do.
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
        await apply(cookies: session.cookies.compactMap(\.httpCookie), to: dataStore)
    }

    private static func apply(cookies: [HTTPCookie], to dataStore: WKWebsiteDataStore) async -> Bool {
        let now = Date()
        var restored = false
        for cookie in cookies {
            if let exp = cookie.expiresDate, exp <= now { continue }
            await dataStore.httpCookieStore.setCookie(cookie)
            restored = true
        }
        return restored
    }

    nonisolated private static func fingerprint(of cookies: [SyncedCookie]) -> String {
        let pairs = cookies
            .map { "\($0.name)=\($0.value)|\($0.domain)\($0.path)" }
            .sorted()
            .joined(separator: ";")
        let digest = SHA256.hash(data: Data(pairs.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
        let version: Int
        let updatedAt: Date?
        let cookies: [SyncedCookie]

        init(cookies: [SyncedCookie], updatedAt: Date) {
            self.version = 2
            self.updatedAt = updatedAt
            self.cookies = cookies
        }

        // Backcompat: v1 payloads have no `version`/`updatedAt` — decode them
        // as version 1 with a nil timestamp so the freshest-wins picker treats
        // them as distantPast and prefers any cloud bundle that does have one.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
            cookies = try c.decode([SyncedCookie].self, forKey: .cookies)
        }

        var fingerprint: String { ClaudeWebSessionSync.fingerprint(of: cookies) }

        enum CodingKeys: String, CodingKey {
            case version
            case updatedAt
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
        let sameSiteRaw: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expiresDate = cookie.expiresDate
            isSecure = cookie.isSecure
            sameSiteRaw = cookie.sameSitePolicy?.rawValue
        }

        enum CodingKeys: String, CodingKey {
            case name, value, domain, path, expiresDate, isSecure, sameSiteRaw
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            value = try c.decode(String.self, forKey: .value)
            domain = try c.decode(String.self, forKey: .domain)
            path = try c.decode(String.self, forKey: .path)
            expiresDate = try c.decodeIfPresent(Date.self, forKey: .expiresDate)
            isSecure = try c.decode(Bool.self, forKey: .isSecure)
            sameSiteRaw = try c.decodeIfPresent(String.self, forKey: .sameSiteRaw)
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
            if let sameSiteRaw {
                properties[.sameSitePolicy] = sameSiteRaw
            }
            return HTTPCookie(properties: properties)
        }
    }
}
