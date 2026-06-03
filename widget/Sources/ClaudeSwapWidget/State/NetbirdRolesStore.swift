import Foundation

/// Role a NetBird group plays in the access matrix. NetBird group names are
/// arbitrary (VPS, private-servers, admin…), so the admin tags each group here
/// rather than relying on a naming convention. Persisted in UserDefaults.
enum NBGroupRole: String, CaseIterable {
    case server
    case dev
}

enum NetbirdRolesStore {
    private static let key = "netbird.groupRoles.v1"

    /// groupName → role.rawValue
    static func load() -> [String: NBGroupRole] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return [:] }
        var out: [String: NBGroupRole] = [:]
        for (g, r) in raw { if let role = NBGroupRole(rawValue: r) { out[g] = role } }
        return out
    }

    static func save(_ roles: [String: NBGroupRole]) {
        let raw = roles.mapValues(\.rawValue)
        UserDefaults.standard.set(raw, forKey: key)
    }
}
