import Foundation

/// Extracts a stable identifier from a Claude Code OAuth Keychain blob.
///
/// The blob is JSON whose exact shape is undocumented and varies between
/// Claude Code versions, so we recursively search for any of the common
/// account-identifying keys (uuid, email, etc.). First match wins.
///
/// Used by the add-account wizards to detect when the user is about to
/// snapshot an identity that's already saved — bytes differ between
/// snapshots (access/refresh tokens rotate), but the account identifier
/// stays stable.
enum OAuthBlobInspector {

    private static let identifierKeys: [String] = [
        "uuid",
        "userId",
        "user_id",
        "userUuid",
        "user_uuid",
        "accountId",
        "account_id",
        "accountUuid",
        "account_uuid",
        "subscriberId",
        "subscriber_id",
        "sub",
        "email",
        "email_address",
        "emailAddress"
    ]

    /// Returns the first identifier-like value found anywhere in the blob,
    /// or nil if the blob can't be parsed as JSON.
    static func identifier(from blob: String) -> String? {
        guard !blob.isEmpty,
              let data = blob.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return search(in: parsed)
    }

    /// Token-stripped signature: serialize the blob with all known ephemeral
    /// token/timestamp fields removed, sorted-keys, as a stable string.
    /// Two blobs from the same account share a signature even when their
    /// `access_token + refresh_token + expires_at` rotated between snapshots.
    ///
    /// Returns nil when:
    ///  - blob isn't JSON
    ///  - after stripping, the remainder is empty / trivial (avoids
    ///    matching every blob to every other blob when there's no account
    ///    metadata left)
    static func stableSignature(from blob: String) -> String? {
        guard !blob.isEmpty,
              let data = blob.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        let stripped = stripEphemeral(parsed)
        guard let stableData = try? JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys]),
              let str = String(data: stableData, encoding: .utf8) else {
            return nil
        }
        // Reject signatures with too little remaining content — pure-token
        // blobs would all reduce to {} and dedupe everything.
        let trimmed = str.trimmingCharacters(in: CharacterSet(charactersIn: "{}[] \"\n\t"))
        guard trimmed.count >= 8 else { return nil }
        return str
    }

    private static let ephemeralKeys: Set<String> = [
        "accessToken", "access_token", "AccessToken",
        "refreshToken", "refresh_token", "RefreshToken",
        "expiresAt", "expires_at", "ExpiresAt",
        "expiresIn", "expires_in",
        "iat", "exp", "nbf", "jti",
        "token", "id_token", "idToken",
        "issued_at", "issuedAt",
        "createdAt", "created_at",
        "updatedAt", "updated_at",
        "lastRefreshedAt", "last_refreshed_at"
    ]

    private static func stripEphemeral(_ obj: Any) -> Any {
        if let dict = obj as? [String: Any] {
            var result: [String: Any] = [:]
            for (k, v) in dict where !ephemeralKeys.contains(k) {
                result[k] = stripEphemeral(v)
            }
            return result
        }
        if let arr = obj as? [Any] {
            return arr.map(stripEphemeral)
        }
        return obj
    }

    private static func search(in any: Any) -> String? {
        if let dict = any as? [String: Any] {
            for key in identifierKeys {
                if let value = dict[key] as? String, !value.isEmpty {
                    return value
                }
            }
            for (_, value) in dict {
                if let found = search(in: value) {
                    return found
                }
            }
        }
        if let arr = any as? [Any] {
            for element in arr {
                if let found = search(in: element) {
                    return found
                }
            }
        }
        return nil
    }
}
