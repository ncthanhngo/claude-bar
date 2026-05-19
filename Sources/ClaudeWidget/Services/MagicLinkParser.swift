import Foundation

/// Pure helpers for working with Claude magic-link URLs.
/// Format: `https://claude.ai/magic-link#<hex-token>:<base64-email>`
enum MagicLinkParser {

    /// Extract the embedded email address from the URL fragment, if present.
    /// Returns nil for any malformed input — never throws.
    static func decodeEmail(from url: URL) -> String? {
        guard let fragment = url.fragment,
              let colonIdx = fragment.firstIndex(of: ":") else { return nil }
        let b64 = String(fragment[fragment.index(after: colonIdx)...])
        guard let data = Data(base64Encoded: b64),
              let email = String(data: data, encoding: .utf8),
              !email.isEmpty else { return nil }
        return email
    }

    /// Loose validation: claude.ai host + fragment that looks like
    /// `token:base64`. Used by the input field to enable/disable Login.
    static func isLikelyMagicLink(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.host == "claude.ai",
              url.path.contains("magic-link") else { return false }
        return url.fragment?.contains(":") == true
    }
}
