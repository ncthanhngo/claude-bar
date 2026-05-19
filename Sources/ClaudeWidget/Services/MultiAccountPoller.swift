import Foundation

/// Fetches usage for every account that has a saved `sessionKey + orgId`,
/// updating `Account.lastSessionPercent` per row so the UI can render
/// realtime % for non-active accounts.
///
/// Sequential by necessity: `WebSessionClient` shares one cookie store, so
/// each account's fetch must swap the cookie, hit the API, then move on.
/// After the round, the active account's cookie is restored so the main
/// `fetchWebUsage` path keeps working.
@MainActor
enum MultiAccountPoller {

    /// Iterates pollable accounts, fetches usage for each, persists
    /// observations to disk. Returns the updated `[Account]` list (caller
    /// is responsible for republishing).
    @discardableResult
    static func runRound(accounts: [Account], activeId: UUID?) async -> [Account] {
        // Save the active account's cookie so we can restore it after the round.
        // Captured outside the loop so a thrown error still triggers the restore
        // path via the `restore` closure called from both success + failure.
        let activeSessionKey = WebUsageService.loadSessionKey()

        var updated = accounts
        for account in accounts {
            // Skip active — main fetchWebUsage handles it on its own cadence.
            if account.id == activeId { continue }
            guard let key = account.sessionKey, !key.isEmpty,
                  let orgId = account.orgId, !orgId.isEmpty else { continue }

            if let snap = await fetchOne(sessionKey: key, orgId: orgId) {
                if let idx = updated.firstIndex(where: { $0.id == account.id }) {
                    updated[idx].lastSessionPercent = snap.utilization
                    updated[idx].lastSessionResetsAt = snap.resetsAt
                    updated[idx].lastObservedAt = Date()
                    try? AccountStore.update(updated[idx])
                }
            }
        }

        // Always restore — even if loop saw partial failures, the active
        // account's cookie must end up back in WebKit so HeroCard data is sane.
        await restoreActiveCookie(activeSessionKey)
        return updated
    }

    private static func restoreActiveCookie(_ key: String?) async {
        if let key {
            await WebSessionClient.shared.setSessionKey(key)
        } else {
            await WebSessionClient.shared.clearSession()
        }
    }

    // MARK: - One-shot

    private struct OneShot {
        let utilization: Double
        let resetsAt: Date?
    }

    private static func fetchOne(sessionKey: String, orgId: String) async -> OneShot? {
        await WebSessionClient.shared.setSessionKey(sessionKey)
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else {
            return nil
        }
        do {
            let data = try await WebSessionClient.shared.fetchJSON(url: url)
            let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            return OneShot(
                utilization: decoded.fiveHour?.utilization ?? 0,
                resetsAt: decoded.fiveHour?.resetsAt
            )
        } catch {
            return nil
        }
    }
}
