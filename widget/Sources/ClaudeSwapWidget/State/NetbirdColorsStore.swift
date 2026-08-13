import Foundation

/// Per-group accent colors (groupName → 0xRRGGBB). Lets the admin color-code
/// dev groups and server clusters for quick visual distinction. Persisted in
/// UserDefaults; non-secret. Colors are chosen from a fixed editorial palette.
///
/// Stored as a JSON-string under `netbird.groupColors.v1.json` so the
/// PreferencesCloudSync whitelist (string-only) carries it across Macs. Legacy
/// dict at `netbird.groupColors.v1` is read once for migration.
enum NetbirdColorsStore {
    private static let key = "netbird.groupColors.v1.json"
    private static let legacyKey = "netbird.groupColors.v1"

    /// Curated swatch palette offered in the picker.
    static let swatches: [UInt32] = [
        0xD2785A, 0x4A6FA5, 0x3F9D6D, 0xC79320, 0x8A5266,
        0x5E7A5C, 0xB0573F, 0x7B6CA8, 0x3C8C8C, 0xC65D7B,
    ]

    static func load() -> [String: UInt32] {
        if let s = UserDefaults.standard.string(forKey: key),
           let data = s.data(using: .utf8),
           let raw = try? JSONDecoder().decode([String: UInt32].self, from: data) {
            return raw
        }
        guard let raw = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: Int] else { return [:] }
        let migrated = raw.mapValues { UInt32(truncatingIfNeeded: $0) }
        save(migrated) // write-back so iCloud sync picks up legacy data on first launch
        return migrated
    }

    static func save(_ colors: [String: UInt32]) {
        guard let data = try? JSONEncoder().encode(colors),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: key)
    }
}
