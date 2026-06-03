import Foundation

/// Per-group freeform markdown notes (groupName → markdown text). Lets the admin
/// jot context for a dev/server group — purpose, owner, caveats, runbook links —
/// surfaced on hover in the matrix. Persisted in UserDefaults; non-secret.
/// Mirrors `NetbirdColorsStore` so group metadata shares one storage idiom.
enum NetbirdNotesStore {
    private static let key = "netbird.groupNotes.v1"

    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func save(_ notes: [String: String]) {
        UserDefaults.standard.set(notes, forKey: key)
    }
}
