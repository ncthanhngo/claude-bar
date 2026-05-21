import Foundation

/// Mirrors backend/internal/domain/account.go Account.
struct AccountDTO: Codable, Hashable {
    let number: Int
    let email: String
    let organizationName: String?
    let organizationUuid: String?
    let nickname: String?
    let createdAt: Date

    var displayName: String {
        if let n = nickname, !n.isEmpty { return n }
        return email
    }

    /// True when the org name is the auto-generated personal placeholder
    /// (e.g. "alice@example.com's Organization") and worth hiding.
    var hasMeaningfulOrg: Bool {
        guard let org = organizationName, !org.isEmpty else { return false }
        return org != "\(email)'s Organization"
    }

    /// One-letter initial for the avatar circle.
    var initial: String {
        let src = displayName.trimmingCharacters(in: .whitespaces)
        return src.isEmpty ? "?" : String(src.prefix(1)).uppercased()
    }
}

/// Mirrors backend/internal/domain/usage.go Window.
///
/// `utilizationPct` is already a percentage in [0, 100] (the Anthropic
/// usage API returns "utilization" as a percent, not a fraction).
struct UsageWindowDTO: Codable, Hashable {
    let utilizationPct: Double
    let resetsAt: Date

    var percentInt: Int { Int(utilizationPct.rounded()) }
    var fractionForBar: Double { max(0, min(1, utilizationPct / 100)) }

    func secondsUntilReset(now: Date = Date()) -> Int {
        max(0, Int(resetsAt.timeIntervalSince(now)))
    }

    /// Consistent reset countdown: "12m", "3h 49m", "2d 8h".
    func resetLabel(now: Date = Date()) -> String {
        let secs = secondsUntilReset(now: now)
        if secs == 0 { return "now" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h >= 24 {
            let d = h / 24
            let rh = h % 24
            return rh == 0 ? "\(d)d" : "\(d)d \(rh)h"
        }
        if h >= 1 { return "\(h)h \(m)m" }
        return "\(max(1, m))m"
    }
}

/// Mirrors backend/internal/domain/usage.go Usage.
struct UsageDTO: Codable, Hashable {
    let fiveHour: UsageWindowDTO?
    let sevenDay: UsageWindowDTO?
    let fetchedAt: Date
}

/// Mirrors backend/internal/usecase/list_accounts.go AccountView.
struct AccountViewDTO: Codable, Hashable, Identifiable {
    let account: AccountDTO
    let isActive: Bool
    let usage: UsageDTO?
    let error: String?
    let credentialState: String?
    let credentialError: String?
    let subscriptionType: String?

    var id: Int { account.number }

    /// Tier for auto-swap selection: Max 200 = 3, Max 100 = 2, Pro = 1, other = 0.
    var subscriptionTier: Int {
        guard let t = subscriptionType?.lowercased() else { return 0 }
        if t.contains("200") { return 3 }
        if t.contains("100") { return 2 }
        if t.contains("pro") { return 1 }
        return 0
    }
}

/// Mirrors backend ListAccountsResult.
struct ListAccountsDTO: Codable, Hashable {
    let accounts: [AccountViewDTO]
    let activeAccountNumber: Int

    var active: AccountViewDTO? { accounts.first(where: { $0.isActive }) }
}

/// Mirrors backend/internal/domain/session.go SessionReport.
struct SessionReportDTO: Codable, Hashable {
    let total: Int
    let busyOrWaiting: Int
    let interactiveOnly: Int
    let safeToSwap: Bool
}

/// Mirrors backend AddAccountResult.
struct AddAccountDTO: Codable, Hashable {
    let account: AccountDTO
    let wasDuplicate: Bool
    let duplicateOfNum: Int?
}

/// Mirrors backend/internal/domain/verification.go CheckResult.
struct CheckResultDTO: Codable, Hashable, Identifiable {
    let name: String
    let passed: Bool
    var skipped: Bool? = nil
    var detail: String? = nil

    var id: String { name }
    var label: String {
        switch name {
        case "credentials_present": return "Credentials present"
        case "credentials_valid":   return "Credentials valid"
        case "token_refresh":       return "Token refresh"
        case "usage_reachable":     return "Usage API reachable"
        default:                    return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Mirrors AccountVerification.
struct AccountVerificationDTO: Codable, Hashable, Identifiable {
    let accountNum: Int
    let email: String
    let displayName: String
    let isActive: Bool
    let checks: [CheckResultDTO]
    let swapReady: Bool

    var id: Int { accountNum }
}

/// Mirrors VerificationReport.
struct VerificationReportDTO: Codable, Hashable {
    let results: [AccountVerificationDTO]
    let total: Int
    let ready: Int
    let failed: Int
}

// MARK: - Local MCP

/// Mirrors the envelope returned by `csw mcp status --json`. Bundles install
/// state with a build-time flag indicating whether csw was built with a
/// default Google OAuth client ID (`-ldflags=-X main.defaultGDriveClientID=…`).
struct MCPInstallStatusDTO: Codable, Hashable {
    let installed: Bool
    let command: String?
    let conflict: Bool?
    let hasDefaultGDriveClient: Bool?
}

/// Mirrors backend/internal/usecase/mcp_connectors.go MCPConnectorSummary.
struct MCPConnectorSummaryDTO: Codable, Hashable, Identifiable {
    let service: String
    let enabled: Bool
    let hasSecret: Bool
    let displayName: String?
    let account: String?
    let needsReauth: Bool
    let connectedAt: Date?
    let usesShared: Bool?

    var id: String { service }

    var labelTitle: String {
        switch service {
        case "slack":   return "Slack"
        case "clickup": return "ClickUp"
        case "gdrive":  return "Google"
        default:        return service.capitalized
        }
    }

    var systemImageName: String {
        switch service {
        case "slack":   return "bubble.left.and.bubble.right"
        case "clickup": return "checklist"
        case "gdrive":  return "folder.fill"
        default:        return "puzzlepiece.extension"
        }
    }

    var state: String {
        if needsReauth { return "needs re-auth" }
        if enabled && hasSecret { return "connected" }
        if usesShared == true { return "using shared" }
        if hasSecret { return "disabled" }
        return "not connected"
    }
}

/// Mirrors backend/internal/usecase/mcp_connectors.go MCPAccountSummary.
struct MCPAccountSummaryDTO: Codable, Hashable, Identifiable {
    let accountNumber: Int
    let displayName: String
    let active: Bool
    let shared: Bool?
    let connectors: [MCPConnectorSummaryDTO]

    var id: Int { accountNumber }
}
