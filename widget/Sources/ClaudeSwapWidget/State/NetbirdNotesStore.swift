import Foundation

/// Per-group freeform markdown notes (groupName → markdown text). Lets the admin
/// jot context for a dev/server group — purpose, owner, caveats, runbook links —
/// surfaced on hover in the matrix. Persisted in UserDefaults; non-secret.
///
/// Stored as a JSON-string under `netbird.groupNotes.v1.json` so the
/// PreferencesCloudSync whitelist (string-only) carries it across Macs. Legacy
/// dict at `netbird.groupNotes.v1` is read once for migration.
enum NetbirdNotesStore {
    private static let key = "netbird.groupNotes.v1.json"
    private static let legacyKey = "netbird.groupNotes.v1"

    static func load() -> [String: String] {
        if let s = UserDefaults.standard.string(forKey: key),
           let data = s.data(using: .utf8),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            return raw
        }
        let migrated = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: String] ?? [:]
        if !migrated.isEmpty {
            save(migrated) // write-back so iCloud sync picks up legacy data on first launch
        }
        return migrated
    }

    static func save(_ notes: [String: String]) {
        guard let data = try? JSONEncoder().encode(notes),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: key)
    }
}
