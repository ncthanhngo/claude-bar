import Foundation

/// File-backed key/value store for app-owned secrets.
///
/// Stored as one JSON dictionary under
/// `~/Library/Application Support/ClaudeWidget/<filename>`, file mode 0600.
///
/// Why not Keychain: each rebuild of an ad-hoc-signed binary changes the
/// designated requirement, so macOS re-prompts the user every few minutes
/// to "use confidential information stored in 'ClaudeWidget-…'". Until the
/// app is properly code-signed with a stable identity, file storage gives
/// a much better UX with equivalent practical protection (user-only file
/// permissions + the same TCC boundaries Keychain Items respect anyway).
struct SecretStore {

    let filename: String

    static let widget = SecretStore(filename: "widget-secrets.json")

    // MARK: - Public API (mirrors KeychainStore)

    func read(_ account: String) -> String? {
        loadDict()[account]
    }

    @discardableResult
    func write(_ account: String, value: String) -> Bool {
        var dict = loadDict()
        dict[account] = value
        return saveDict(dict)
    }

    @discardableResult
    func delete(_ account: String) -> Bool {
        var dict = loadDict()
        dict.removeValue(forKey: account)
        return saveDict(dict)
    }

    // MARK: - Storage

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(filename)
    }

    private func loadDict() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    @discardableResult
    private func saveDict(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        do {
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }
}
