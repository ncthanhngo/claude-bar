import Foundation

/// Talks to `claude.ai/api/*` via `WebSessionClient`. Owns no persistent
/// state — sessionKey + orgId live in `SecretStore.widget`.
enum WebUsageService {

    private enum Key {
        static let sessionKey = "sessionKey"
        static let orgId      = "organizationId"
    }

    // MARK: - Credentials

    static func storeCredentials(sessionKey: String, orgId: String) {
        SecretStore.widget.write(Key.sessionKey, value: sessionKey)
        SecretStore.widget.write(Key.orgId,      value: orgId)
    }
    static func loadSessionKey() -> String? { SecretStore.widget.read(Key.sessionKey) }
    static func loadOrgId() -> String?      { SecretStore.widget.read(Key.orgId) }

    static func clearCredentials() {
        SecretStore.widget.delete(Key.sessionKey)
        SecretStore.widget.delete(Key.orgId)
    }

    // MARK: - Network

    struct Snapshot {
        let sessionUtilization: Double
        let sessionResetsAt: Date?
        let weeklyUtilization: Double?
        let weeklyResetsAt: Date?
        let fetchedAt: Date
    }

    /// One-shot fetch of the usage snapshot. Throws `WebSessionClient.WebError`.
    @MainActor
    static func fetchSnapshot() async throws -> Snapshot {
        guard let sessionKey = loadSessionKey(), let orgId = loadOrgId() else {
            throw WebSessionClient.WebError.noSession
        }
        await WebSessionClient.shared.setSessionKey(sessionKey)

        let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!
        let data = try await WebSessionClient.shared.fetchJSON(url: url)
        let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        return Snapshot(
            sessionUtilization: decoded.fiveHour?.utilization ?? 0,
            sessionResetsAt: decoded.fiveHour?.resetsAt,
            weeklyUtilization: decoded.sevenDay?.utilization,
            weeklyResetsAt: decoded.sevenDay?.resetsAt,
            fetchedAt: Date()
        )
    }

    /// Validates `sessionKey` and returns the primary orgId.
    @MainActor
    static func validateAndDetectOrg(sessionKey: String) async throws -> String {
        await WebSessionClient.shared.setSessionKey(sessionKey)
        let url = URL(string: "https://claude.ai/api/organizations")!
        let data = try await WebSessionClient.shared.fetchJSON(url: url)
        let list = try JSONDecoder().decode([ClaudeOrgListEntry].self, from: data)
        guard let first = list.first else {
            throw WebSessionClient.WebError.decode("no organizations on account")
        }
        return first.uuid
    }
}
