import Foundation

/// Verifies whether saved accounts can participate in the auto-switch chain.
///
/// For each account we check:
///  - **OAuth blob present** — required to switch the CLI (always true at
///    snapshot time, but stored value could be tampered/corrupted).
///  - **Web session present** — `sessionKey + orgId` saved on the row.
///  - **Web session valid** — actually fetch `/api/organizations` with the
///    stored cookie; failure = session expired or revoked.
///
/// Sequential, ~2-5s per account (Cloudflare + WebKit render). Active
/// account's cookie is restored at the end so the main `fetchWebUsage`
/// path keeps working.
@MainActor
enum AccountReadinessChecker {

    enum Status: Equatable {
        case checking
        case ready
        case missingOAuthBlob
        case missingWebSession
        case webSessionExpired
    }

    struct Result: Identifiable, Equatable {
        let id: UUID
        let label: String
        let status: Status
        let reason: String
        let fix: String?
    }

    static func check(
        accounts: [Account],
        onResult: @MainActor @escaping (Result) -> Void
    ) async {
        let savedKey = WebUsageService.loadSessionKey()
        for acc in accounts {
            onResult(Result(id: acc.id, label: acc.displayName, status: .checking, reason: "Checking…", fix: nil))
            let r = await checkOne(acc)
            onResult(r)
        }
        if let key = savedKey {
            await WebSessionClient.shared.setSessionKey(key)
        } else {
            await WebSessionClient.shared.clearSession()
        }
    }

    // MARK: - Per-account

    private static func checkOne(_ account: Account) async -> Result {
        // OAuth blob — required to switch CLI Keychain.
        if account.oauthBlob.isEmpty {
            return Result(
                id: account.id,
                label: account.displayName,
                status: .missingOAuthBlob,
                reason: "No OAuth credentials saved for this account.",
                fix: "Remove this row, then re-add via Add → Open Claude login (or Magic link). A fresh `claude` OAuth flow is required."
            )
        }

        // Web session presence.
        guard let key = account.sessionKey, !key.isEmpty,
              let orgId = account.orgId, !orgId.isEmpty else {
            return Result(
                id: account.id,
                label: account.displayName,
                status: .missingWebSession,
                reason: "No claude.ai web session saved. Auto-switch will skip this account when picking a candidate.",
                fix: "In the popover, click ⋯ on this row → Connect web. Sign in as this account when the window opens."
            )
        }

        // Web session liveness.
        do {
            _ = try await WebUsageService.validateAndDetectOrg(sessionKey: key)
            _ = orgId
            return Result(
                id: account.id,
                label: account.displayName,
                status: .ready,
                reason: "Switchable + pollable.",
                fix: nil
            )
        } catch {
            return Result(
                id: account.id,
                label: account.displayName,
                status: .webSessionExpired,
                reason: "Web session is expired or rejected (\(error.localizedDescription)).",
                fix: "Click ⋯ on this row → Reconnect web to refresh the cookie."
            )
        }
    }
}
