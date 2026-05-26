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

    var identityKey: String {
        email + "|" + (organizationUuid ?? "")
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

    /// True when any present window already rolled over. Mirrors
    /// `domain.Usage.HasPastResetWindow` on the backend side.
    var hasPastResetWindow: Bool {
        let now = Date()
        if let five = fiveHour, five.resetsAt < now { return true }
        if let seven = sevenDay, seven.resetsAt < now { return true }
        return false
    }

    /// Merge per-window with a previous snapshot: when this fetch is missing
    /// a window, keep the previous one as long as it has not rolled over.
    /// The web scraper occasionally returns `sevenDay: nil` because the
    /// weekly-limit block hydrates later than the 5h block on claude.ai, and
    /// the OAuth API can also omit one window on a transient response. Without
    /// this merge the 7d bar would flicker on/off between refresh ticks.
    func merging(over previous: UsageDTO?) -> UsageDTO {
        guard let previous else { return self }
        let now = Date()
        let mergedFive = fiveHour ?? (previous.fiveHour?.resetsAt ?? .distantPast > now ? previous.fiveHour : nil)
        let mergedSeven = sevenDay ?? (previous.sevenDay?.resetsAt ?? .distantPast > now ? previous.sevenDay : nil)
        return UsageDTO(fiveHour: mergedFive, sevenDay: mergedSeven, fetchedAt: fetchedAt)
    }
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

    func replacingUsage(_ usage: UsageDTO) -> AccountViewDTO {
        AccountViewDTO(
            account: account,
            isActive: isActive,
            usage: usage.merging(over: self.usage),
            error: error,
            credentialState: credentialState,
            credentialError: credentialError,
            subscriptionType: subscriptionType
        )
    }

    func preservingUsageState(from previous: AccountViewDTO?) -> AccountViewDTO {
        guard let previous else { return self }
        return AccountViewDTO(
            account: account,
            isActive: isActive,
            usage: usage ?? previous.usage,
            error: error ?? previous.error,
            credentialState: credentialState ?? previous.credentialState,
            credentialError: credentialError ?? previous.credentialError,
            subscriptionType: subscriptionType ?? previous.subscriptionType
        )
    }

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

    func replacingActiveUsage(_ usage: UsageDTO) -> ListAccountsDTO {
        ListAccountsDTO(
            accounts: accounts.map { $0.isActive ? $0.replacingUsage(usage) : $0 },
            activeAccountNumber: activeAccountNumber
        )
    }

    func preservingUsageState(from previous: ListAccountsDTO?) -> ListAccountsDTO {
        guard let previous else { return self }
        return ListAccountsDTO(
            accounts: accounts.map { account in
                account.preservingUsageState(
                    from: previous.accounts.first(where: { $0.id == account.id })
                )
            },
            activeAccountNumber: activeAccountNumber
        )
    }

    func mergingUsageRows(_ rows: ListAccountsDTO) -> ListAccountsDTO {
        ListAccountsDTO(
            accounts: accounts.map { account in
                guard let row = rows.accounts.first(where: { $0.id == account.id }) else {
                    return account
                }
                // Backend returns every account but only fills `usage` for
                // those in `--usage-accounts`. For web-linked accounts the
                // fallback batch intentionally excludes them, so `row.usage`
                // is nil — keep this account's preserved usage in that case,
                // otherwise the subsequent web overlay sees `self.usage = nil`
                // and merge-over-previous can't recover the 7d window when
                // the scraper only returns the 5h block.
                guard row.usage != nil else { return account }
                return row
            },
            activeAccountNumber: activeAccountNumber
        )
    }

    func replacingUsage(_ usages: [Int: UsageDTO]) -> ListAccountsDTO {
        ListAccountsDTO(
            accounts: accounts.map { account in
                guard let usage = usages[account.id] else { return account }
                return account.replacingUsage(usage)
            },
            activeAccountNumber: activeAccountNumber
        )
    }
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
        case "github":  return "GitHub"
        default:        return service.capitalized
        }
    }

    var systemImageName: String {
        switch service {
        case "slack":   return "bubble.left.and.bubble.right"
        case "clickup": return "checklist"
        case "gdrive":  return "folder.fill"
        case "github":  return "chevron.left.forwardslash.chevron.right"
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

/// Mirrors backend/internal/usecase/mcp_connectors.go MCPToolSummary.
/// One toggleable tool with the metadata the widget needs to render a
/// labelled, described, grouped, sorted row. `priority` is a low-int
/// enum (0 = essential, 1 = common, 2 = advanced) used to bucket tools
/// inside their connector's disclosure.
struct MCPToolSummaryDTO: Codable, Hashable, Identifiable {
    let id: String
    let service: String
    let label: String
    let description: String
    let category: String
    let priority: Int
    let enabled: Bool
    let tokenCost: Int
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

// MARK: - Token usage stats

/// Mirrors backend/internal/domain/usage_stats.go UsageStatsReport.
/// Source = local ~/.claude/projects/**/*.jsonl session logs.
struct UsageStatsDTO: Codable, Hashable {
    let today: UsageBucketDTO
    let thisWeek: UsageBucketDTO
    let thisMonth: UsageBucketDTO
    let hourly: [TimedBucketDTO]
    let daily: [TimedBucketDTO]
    let monthly: [TimedBucketDTO]
    /// Rate table the `estimatedCostUsd` column was computed against.
    /// Shipped from backend (domain.PublishedPricing) so the "Details"
    /// popover and the chart never drift.
    let pricing: [ModelPricingDTO]
    /// Free-form snapshot tag for the pricing table (e.g. source URL + date).
    let pricingReference: String
    let fetchedAt: Date
}

/// Mirrors backend/internal/domain/pricing.go ModelPricing.
/// Values are USD per 1,000,000 tokens for one model family.
struct ModelPricingDTO: Codable, Hashable, Identifiable {
    let family: String
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    var id: String { family }
}

/// One slot in a histogram series. `start` is the inclusive lower bound; the
/// upper bound is implicit (next slot, or now for the final slot).
struct TimedBucketDTO: Codable, Hashable, Identifiable {
    let start: Date
    let bucket: UsageBucketDTO

    var id: Date { start }
}

struct UsageBucketDTO: Codable, Hashable {
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64
    /// Sum of input + output + cache_write. Cache reads are tracked separately
    /// because they would otherwise dominate the headline number.
    let totalTokens: Int64
    /// Estimated dollar cost at Anthropic's published per-model rates,
    /// computed across all four token flows (including cache reads).
    let estimatedCostUsd: Double
    let requests: Int
}
