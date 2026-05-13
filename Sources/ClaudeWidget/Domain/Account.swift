import Foundation

/// A saved Claude Code account. Holds an opaque snapshot of the Keychain
/// `Claude Code-credentials` entry plus optional metadata.
struct Account: Codable, Identifiable, Hashable {
    let id: UUID
    var label: String          // user-facing name ("work", "personal")
    var email: String?         // detected from /api/organizations on add (best-effort)
    var oauthBlob: String      // raw Keychain `Claude Code-credentials` value
    var sessionKey: String?    // optional claude.ai web cookie value
    var orgId: String?         // optional claude.ai organization UUID
    let createdAt: Date
    var lastSwitchedAt: Date?
    /// Most recent usage snapshot we observed for this account, if any.
    var lastSessionPercent: Double?
    var lastSessionResetsAt: Date?
    var lastObservedAt: Date?

    init(id: UUID = UUID(),
         label: String,
         email: String? = nil,
         oauthBlob: String,
         sessionKey: String? = nil,
         orgId: String? = nil,
         createdAt: Date = Date(),
         lastSwitchedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.email = email
        self.oauthBlob = oauthBlob
        self.sessionKey = sessionKey
        self.orgId = orgId
        self.createdAt = createdAt
        self.lastSwitchedAt = lastSwitchedAt
    }

    /// Display: prefer email, fall back to label.
    var displayName: String { email ?? label }
}
