import Foundation

/// Role a NetBird group plays in the access matrix. NetBird group names are
/// arbitrary (VPS, private-servers, admin…), so the admin tags each group here
/// rather than relying on a naming convention. Persisted in UserDefaults.
enum NBGroupRole: String, CaseIterable {
    case server
    case dev
}

/// Stored as a JSON-string under `netbird.groupRoles.v1.json` so the
/// PreferencesCloudSync whitelist (string-only) carries it across Macs. Legacy
/// dict at `netbird.groupRoles.v1` is read once for migration; new writes never
/// touch it.
enum NetbirdRolesStore {
    private static let key = "netbird.groupRoles.v1.json"
    private static let legacyKey = "netbird.groupRoles.v1"

    static func load() -> [String: NBGroupRole] {
        if let s = UserDefaults.standard.string(forKey: key),
           let data = s.data(using: .utf8),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            return raw.compactMapValues(NBGroupRole.init(rawValue:))
        }
        guard let raw = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: String] else { return [:] }
        let migrated = raw.compactMapValues(NBGroupRole.init(rawValue:))
        save(migrated) // write-back so iCloud sync picks up legacy data on first launch
        return migrated
    }

    static func save(_ roles: [String: NBGroupRole]) {
        let raw = roles.mapValues(\.rawValue)
        guard let data = try? JSONEncoder().encode(raw),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: key)
    }
}
