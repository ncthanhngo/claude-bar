import Foundation

/// Persists Claude Code accounts in `~/Library/Application Support/ClaudeWidget/accounts.json`
/// (file mode 0600). Each account holds an opaque snapshot of Claude Code's
/// Keychain OAuth blob plus optional web-session metadata.
///
/// Switching = take the chosen account's OAuth blob and `ClaudeCodeCredentials.write`
/// it back into the Keychain entry Claude Code reads on startup.
enum AccountStore {

    /// Single JSON file under `~/Library/Application Support/ClaudeWidget/`.
    /// No Keychain prompts on every rebuild of an ad-hoc-signed binary.
    private static let store = SecretStore(filename: "accounts.json")
    private static let bagKey = "accounts-json"

    // MARK: - List

    static func loadAll() -> [Account] {
        guard let raw = store.read(bagKey),
              let data = raw.data(using: .utf8) else {
            return []
        }
        return (try? decoder.decode([Account].self, from: data)) ?? []
    }

    static func find(id: UUID) -> Account? {
        loadAll().first(where: { $0.id == id })
    }

    // MARK: - Mutation

    enum AccountError: LocalizedError {
        case duplicateLabel
        case notFound
        case noClaudeCodeLogin

        var errorDescription: String? {
            switch self {
            case .duplicateLabel:    return "An account with that label already exists."
            case .notFound:          return "Account not found."
            case .noClaudeCodeLogin: return "No Claude Code login detected. Run `claude` and sign in, then add."
            }
        }
    }

    /// Snapshot whatever Claude Code currently has in its Keychain and save it
    /// as a new account.
    static func addFromCurrentClaudeCode(
        label: String,
        sessionKey: String? = nil,
        orgId: String? = nil,
        email: String? = nil
    ) throws -> Account {
        var bag = loadAll()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if bag.contains(where: { $0.label.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw AccountError.duplicateLabel
        }
        let blob: String
        do { blob = try ClaudeCodeCredentials.read() }
        catch ClaudeCodeCredentials.CredentialError.notFound { throw AccountError.noClaudeCodeLogin }

        let acc = Account(
            label: trimmed,
            email: email,
            oauthBlob: blob,
            sessionKey: sessionKey,
            orgId: orgId
        )
        bag.append(acc)
        try save(bag)
        return acc
    }

    static func update(_ account: Account) throws {
        var bag = loadAll()
        guard let idx = bag.firstIndex(where: { $0.id == account.id }) else {
            throw AccountError.notFound
        }
        bag[idx] = account
        try save(bag)
    }

    static func delete(id: UUID) throws {
        var bag = loadAll()
        guard let idx = bag.firstIndex(where: { $0.id == id }) else {
            throw AccountError.notFound
        }
        bag.remove(at: idx)
        try save(bag)
    }

    /// Apply the account's OAuth blob to Claude Code's keychain entry and
    /// stamp `lastSwitchedAt` on the account.
    @discardableResult
    static func switchTo(id: UUID) throws -> Account {
        var bag = loadAll()
        guard let idx = bag.firstIndex(where: { $0.id == id }) else {
            throw AccountError.notFound
        }
        try ClaudeCodeCredentials.write(bag[idx].oauthBlob)
        bag[idx].lastSwitchedAt = Date()
        try save(bag)
        return bag[idx]
    }

    static func recordObservation(id: UUID, percent: Double, resetsAt: Date?) {
        var bag = loadAll()
        guard let idx = bag.firstIndex(where: { $0.id == id }) else { return }
        bag[idx].lastSessionPercent = percent
        bag[idx].lastSessionResetsAt = resetsAt
        bag[idx].lastObservedAt = Date()
        try? save(bag)
    }

    // MARK: - JSON

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func save(_ bag: [Account]) throws {
        let data = try encoder.encode(bag)
        guard let str = String(data: data, encoding: .utf8) else { return }
        store.write(bagKey, value: str)
    }
}
