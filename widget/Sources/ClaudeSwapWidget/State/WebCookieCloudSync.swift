import CryptoKit
import Foundation
import Security
import WebKit

/// Encrypted iCloud Drive sync for Claude web session cookies, keyed by account
/// email. Shipped as a fallback for `ClaudeWebSessionSync` because the iCloud
/// Keychain path (`kSecAttrSynchronizable: true`) silently fails with
/// `errSecMissingEntitlement` on the ad-hoc-signed Claude Bar build.
///
/// File layout (same trust boundary as `cloud-bundle.enc` — see cloudsync Go
/// package). Separate file so cookies don't entangle with the accounts bundle's
/// hash-chain / ring-buffer machinery; cookies are cheap to re-acquire (user
/// re-logs in) and don't justify the anti-rollback rigor.
///
///   ~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeBar/web-cookies.enc
///
/// Binary layout: magic `WCBR` (4) · version uint16 BE (2) · salt 32 · nonce
/// 12 · ciphertext+tag. AES-256-GCM with PBKDF2-HMAC-SHA256 key derivation
/// (200_000 iter — CryptoKit-only, no CommonCrypto bridging needed).
///
/// Encryption uses the same passphrase as the accounts bundle, loaded from the
/// local Keychain (service `claude-bar-cloudsync-passphrase`). If no passphrase
/// is set, all operations are silent no-ops — caller falls back to local-only
/// Keychain storage.
@MainActor
enum WebCookieCloudSync {

    // MARK: - Public API

    static func save(account: AccountDTO, dataStore: WKWebsiteDataStore) async {
        guard let passphrase = loadPassphrase() else { return }
        let now = Date()
        let cookies = await dataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("claude.ai") }
            .filter { $0.expiresDate.map { $0 > now } ?? true }
            .map(StoredCookie.init)
        guard !cookies.isEmpty else { return }

        do {
            var bundle = try loadOrEmptyBundle(passphrase: passphrase)
            let key = emailKey(for: account)
            // Anti-overwrite: skip if the bundle already holds the same cookie
            // set. Without this, every poll re-pushes identical cookies and
            // can clobber a fresher push from the other device whose iCloud
            // Drive sync arrived seconds later.
            if let existing = bundle.sessions[key],
               existing.fingerprint == StoredSession.fingerprint(of: cookies) {
                return
            }
            bundle.sessions[key] = StoredSession(cookies: cookies, updatedAt: now)
            bundle.updatedAt = now
            try writeBundle(bundle, passphrase: passphrase)
        } catch {
            NSLog("[WebCookieCloudSync] save failed: \(error.localizedDescription)")
        }
    }

    static func restore(account: AccountDTO, dataStore: WKWebsiteDataStore) async -> Bool {
        guard let passphrase = loadPassphrase() else { return false }
        guard let bundle = try? readBundle(passphrase: passphrase),
              let session = bundle.sessions[emailKey(for: account)] else {
            return false
        }
        let now = Date()
        var restored = false
        for cookie in session.cookies.compactMap(\.httpCookie) {
            if let exp = cookie.expiresDate, exp <= now { continue }
            await dataStore.httpCookieStore.setCookie(cookie)
            restored = true
        }
        return restored
    }

    /// Snapshot of the persisted cookies for `account` without touching any
    /// `WKWebsiteDataStore`. Used by [[ClaudeWebSessionSync]] to compare its
    /// local Keychain cache against the cloud bundle and pick the freshest
    /// before applying — prevents stale local state from winning over a fresh
    /// push from the other device.
    static func loadCookies(for account: AccountDTO) -> (cookies: [HTTPCookie], updatedAt: Date)? {
        guard let passphrase = loadPassphrase() else { return nil }
        guard let bundle = try? readBundle(passphrase: passphrase),
              let session = bundle.sessions[emailKey(for: account)] else {
            return nil
        }
        let now = Date()
        let live = session.cookies
            .compactMap(\.httpCookie)
            .filter { $0.expiresDate.map { $0 > now } ?? true }
        return (live, session.updatedAt)
    }

    static func hasSession(for account: AccountDTO) -> Bool {
        guard let passphrase = loadPassphrase(),
              let bundle = try? readBundle(passphrase: passphrase) else {
            return false
        }
        return bundle.sessions[emailKey(for: account)] != nil
    }

    static func remove(account: AccountDTO) {
        guard let passphrase = loadPassphrase() else { return }
        guard var bundle = try? readBundle(passphrase: passphrase) else { return }
        bundle.sessions.removeValue(forKey: emailKey(for: account))
        bundle.updatedAt = Date()
        do {
            try writeBundle(bundle, passphrase: passphrase)
        } catch {
            NSLog("[WebCookieCloudSync] remove failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Paths

    private static var iCloudRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    private static var folderURL: URL {
        iCloudRoot.appendingPathComponent("ClaudeBar", isDirectory: true)
    }

    private static var fileURL: URL {
        folderURL.appendingPathComponent("web-cookies.enc")
    }

    private static var iCloudAvailable: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: iCloudRoot.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Bundle IO

    private static func loadOrEmptyBundle(passphrase: String) throws -> CookieBundle {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        return try readBundle(passphrase: passphrase)
    }

    private static func readBundle(passphrase: String) throws -> CookieBundle {
        let data = try Data(contentsOf: fileURL)
        let plain = try decrypt(data, passphrase: passphrase)
        return try jsonDecoder.decode(CookieBundle.self, from: plain)
    }

    private static func writeBundle(_ bundle: CookieBundle, passphrase: String) throws {
        guard iCloudAvailable else { throw IOError.iCloudUnavailable }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let plain = try jsonEncoder.encode(bundle)
        let cipher = try encrypt(plain, passphrase: passphrase)
        try cipher.write(to: fileURL, options: [.atomic])
    }

    // MARK: - Crypto

    private static let magic = "WCBR"
    private static let version: UInt16 = 1
    private static let saltLen = 32
    private static let nonceLen = 12
    private static let keyLen = 32
    private static let pbkdfIters = 200_000

    private static func encrypt(_ plain: Data, passphrase: String) throws -> Data {
        let salt = try randomBytes(saltLen)
        let key = pbkdf2(passphrase: passphrase, salt: salt, iterations: pbkdfIters, keyLen: keyLen)
        let nonceBytes = try randomBytes(nonceLen)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce)

        var out = Data(capacity: 4 + 2 + saltLen + nonceLen + plain.count + 16)
        out.append(magic.data(using: .ascii)!)
        var v = version.bigEndian
        withUnsafeBytes(of: &v) { out.append(Data($0)) }
        out.append(salt)
        out.append(nonceBytes)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    private static func decrypt(_ data: Data, passphrase: String) throws -> Data {
        let header = 4 + 2 + saltLen + nonceLen
        guard data.count >= header + 16 else { throw CryptoError.malformed }
        guard data.prefix(4) == magic.data(using: .ascii)! else { throw CryptoError.malformed }
        let salt = data.subdata(in: 6..<6 + saltLen)
        let nonceBytes = data.subdata(in: 6 + saltLen..<header)
        let bodyEnd = data.count
        let tagStart = bodyEnd - 16
        let cipher = data.subdata(in: header..<tagStart)
        let tag = data.subdata(in: tagStart..<bodyEnd)

        let key = pbkdf2(passphrase: passphrase, salt: salt, iterations: pbkdfIters, keyLen: keyLen)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    /// PBKDF2-HMAC-SHA256, pure-CryptoKit (no CommonCrypto bridging). 200_000
    /// iter on Apple Silicon ≈ 150-300ms — acceptable for once-per-save.
    private static func pbkdf2(passphrase: String, salt: Data, iterations: Int, keyLen: Int) -> Data {
        let pw = SymmetricKey(data: Data(passphrase.utf8))
        var derived = Data()
        var block: UInt32 = 1
        while derived.count < keyLen {
            var u = salt
            var be = block.bigEndian
            withUnsafeBytes(of: &be) { u.append(Data($0)) }

            var ui = Data(HMAC<SHA256>.authenticationCode(for: u, using: pw))
            var t = ui
            for _ in 1..<iterations {
                ui = Data(HMAC<SHA256>.authenticationCode(for: ui, using: pw))
                for i in 0..<t.count { t[i] ^= ui[i] }
            }
            derived.append(t)
            block += 1
        }
        return derived.prefix(keyLen)
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw CryptoError.rngFailed }
        return bytes
    }

    // MARK: - Passphrase

    /// Read the cloud-sync passphrase that CloudSyncCoordinator persists under
    /// the same Keychain service. Returns nil when the user has not enabled
    /// iCloud cloud sync — in which case every entry point above no-ops.
    /// Also gated on `iCloudSyncEnabled` so a fresh Sparkle build doesn't
    /// trigger the macOS ACL prompt for users who never opted in.
    private static func loadPassphrase() -> String? {
        guard AppSettings.shared.iCloudSyncEnabled else { return nil }
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "claude-bar-cloudsync-passphrase",
            kSecAttrAccount: "passphrase",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip
        ]
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func emailKey(for account: AccountDTO) -> String {
        account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Bundle model

private struct CookieBundle: Codable {
    var version: Int
    var updatedAt: Date
    var sessions: [String: StoredSession]

    static let empty = CookieBundle(version: 1, updatedAt: .distantPast, sessions: [:])
}

private struct StoredSession: Codable {
    let cookies: [StoredCookie]
    let updatedAt: Date

    var fingerprint: String { Self.fingerprint(of: cookies) }

    static func fingerprint(of cookies: [StoredCookie]) -> String {
        let pairs = cookies
            .map { "\($0.name)=\($0.value)|\($0.domain)\($0.path)" }
            .sorted()
            .joined(separator: ";")
        let digest = SHA256.hash(data: Data(pairs.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct StoredCookie: Codable {
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
        if let expiresDate { properties[.expires] = expiresDate }
        if isSecure { properties[.secure] = "TRUE" }
        if let sameSiteRaw { properties[.sameSitePolicy] = sameSiteRaw }
        return HTTPCookie(properties: properties)
    }
}

// MARK: - Errors

private enum CryptoError: Error {
    case malformed
    case rngFailed
}

private enum IOError: Error {
    case iCloudUnavailable
}
