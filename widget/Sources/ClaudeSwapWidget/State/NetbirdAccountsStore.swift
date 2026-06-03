import Foundation

/// Remembers the list of SSH login usernames per server host. Model B (NetBird
/// SSH) has no password/key to store — only which local users you connect as,
/// and a server can have several. Persisted in UserDefaults (non-secret).
enum NetbirdAccountsStore {
    private static let key = "netbird.serverAccounts.v1"

    /// host → [username]. Hosts with no saved users fall back to defaults.
    static func all() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return map
    }

    static func usernames(for host: String) -> [String] {
        let saved = all()[host] ?? []
        return saved.isEmpty ? ["deploy", "root"] : saved
    }

    static func add(username: String, for host: String) {
        let u = username.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        var map = all()
        var list = map[host] ?? []
        if !list.contains(u) { list.append(u) }
        map[host] = list
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
