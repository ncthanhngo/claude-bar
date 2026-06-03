import Foundation

/// Per-group accent colors (groupName → 0xRRGGBB). Lets the admin color-code
/// dev groups and server clusters for quick visual distinction. Persisted in
/// UserDefaults; non-secret. Colors are chosen from a fixed editorial palette.
enum NetbirdColorsStore {
    private static let key = "netbird.groupColors.v1"

    /// Curated swatch palette offered in the picker.
    static let swatches: [UInt32] = [
        0xD2785A, 0x4A6FA5, 0x3F9D6D, 0xC79320, 0x8A5266,
        0x5E7A5C, 0xB0573F, 0x7B6CA8, 0x3C8C8C, 0xC65D7B,
    ]

    static func load() -> [String: UInt32] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] else { return [:] }
        return raw.mapValues { UInt32(truncatingIfNeeded: $0) }
    }

    static func save(_ colors: [String: UInt32]) {
        UserDefaults.standard.set(colors.mapValues { Int($0) }, forKey: key)
    }
}
