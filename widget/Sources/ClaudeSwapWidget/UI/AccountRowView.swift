import SwiftUI

struct AccountRowView: View {
    let view: AccountViewDTO
    let onRename: () -> Void

    @EnvironmentObject var store: AppStore
    @EnvironmentObject var webFallback: WebFallbackCoordinator
    @EnvironmentObject var quickRelogin: QuickReloginCoordinator
    @EnvironmentObject var recovery: CredentialRecoveryCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            // Left accent bar for active account
            if view.isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(settings.widgetTheme.activeAccent)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                titleLine
                subtitleLine
                usageBlock
            }
            .padding(.vertical, 8)
            .padding(.leading, view.isActive ? 9 : 10)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(isHovering && !view.isActive ? Color.primary.opacity(0.06) : Color.clear)
        .overlay {
            // Pulsing glow while a hidden recovery re-login runs for this row.
            if recovery.isRecovering(view.account.number) {
                RecoveryGlowView(accent: settings.widgetTheme.activeAccent)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .allowsHitTesting(store.swappingTo == nil)
        .onHover { isHovering = $0 }
        .contextMenu { AccountActionMenu(view: view, onRename: onRename) }
    }

    private var isSwappingThisRow: Bool { store.swappingTo == view.account.number }
    private var isRefreshingThisRow: Bool { store.refreshingAccountIds.contains(view.id) }

    // MARK: - Title line

    private var titleLine: some View {
        HStack(spacing: 8) {
            AvatarView(
                initial: view.account.initial,
                seed: view.account.email + (view.account.organizationUuid ?? ""),
                size: 24
            )
            .overlay(activeDot, alignment: .bottomTrailing)

            Text(view.account.displayName)
                .font(.system(size: 13, weight: view.isActive ? .semibold : .regular))
                .foregroundColor(.primary)
                .lineLimit(1)

            webUsageBadge
            refreshButton.opacity(isHovering || isRefreshingThisRow ? 1 : 0)

            Spacer(minLength: 4)

            if isSwappingThisRow {
                ProgressView().controlSize(.small)
            } else if view.isActive {
                activeChip
            } else {
                switchButton
            }

            moreButton.opacity(isHovering ? 1 : 0.45)
        }
    }

    @ViewBuilder
    private var activeDot: some View {
        if view.isActive {
            Circle()
                .fill(settings.widgetTheme.activeAccent)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
        }
    }

    private var switchButton: some View {
        Button(action: trySwap) {
            Text("Switch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Switch to this account")
        .accessibilityLabel("Switch to \(view.account.displayName)")
        .accessibilityHint("Switches the active Claude Code account.")
    }

    private var activeChip: some View {
        Text("ACTIVE")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(settings.widgetTheme.activeChipBackground)
            .clipShape(Capsule())
    }

    private var refreshButton: some View {
        Button {
            Task { await store.refreshAccount(view) }
        } label: {
            Group {
                if isRefreshingThisRow {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshingThisRow)
        .pointingHandCursor()
        .help("Refresh usage for this account")
        .accessibilityLabel("Refresh usage for \(view.account.displayName)")
    }

    private var moreButton: some View {
        Menu {
            AccountActionMenu(view: view, onRename: onRename)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
        .accessibilityLabel("More actions for \(view.account.displayName)")
        .accessibilityHint("Rename, switch, remove, or manage web usage.")
    }

    // MARK: - Subtitle

    private var subtitleLine: some View {
        HStack(spacing: 4) {
            Text(view.account.email)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if view.account.hasMeaningfulOrg, let org = view.account.organizationName {
                Text("·").foregroundColor(.secondary.opacity(0.5)).font(.caption)
                Text(org)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 32)
    }

    private var webUsageBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: webUsageIcon)
                .font(.system(size: 8, weight: .semibold))
            Text(webUsageLabel)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(webUsageColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(webUsageColor.opacity(0.12))
        .clipShape(Capsule())
        .help(webUsageHelp)
    }

    /// Minutes remaining on this account's rate-limit backoff, or nil if
    /// not rate-limited. Drives the badge variant — when set, the badge
    /// dominates the connected/linked/fallback display because the user
    /// needs to know polling is paused right now.
    private var rateLimitedMinutesRemaining: Int? {
        guard let until = webFallback.rateLimitedUntil(view.account) else { return nil }
        let secs = until.timeIntervalSinceNow
        guard secs > 0 else { return nil }
        return max(1, Int((secs / 60).rounded(.up)))
    }

    private var webUsageIcon: String {
        if rateLimitedMinutesRemaining != nil { return "clock.badge.exclamationmark" }
        if webFallback.needsWebRelogin(view.account) { return "person.crop.circle.badge.exclamationmark" }
        switch webFallback.state(for: view.account) {
        case .connected: return "checkmark.icloud"
        case .linked: return "globe"
        case .fallback: return "exclamationmark.icloud"
        case .notLinked: return "terminal"
        }
    }

    private var webUsageLabel: String {
        if let mins = rateLimitedMinutesRemaining { return "Wait \(mins)m" }
        if webFallback.needsWebRelogin(view.account) { return "Sign in" }
        switch webFallback.state(for: view.account) {
        case .connected, .linked, .fallback: return "Web"
        case .notLinked: return "Terminal"
        }
    }

    private var webUsageColor: Color {
        if rateLimitedMinutesRemaining != nil { return .red }
        if webFallback.needsWebRelogin(view.account) { return .red }
        switch webFallback.state(for: view.account) {
        case .connected: return .green
        case .fallback: return .orange
        case .linked, .notLinked: return .secondary
        }
    }

    private var webUsageHelp: String {
        if let mins = rateLimitedMinutesRemaining {
            return "claude.ai rate-limited this account. Polling resumes in ~\(mins)m. Other accounts unaffected."
        }
        if webFallback.needsWebRelogin(view.account) {
            return "Web session expired after repeated auth failures. Use Quick Login to refresh usage. CLI is unaffected."
        }
        switch webFallback.state(for: view.account) {
        case .connected(let summary): return "Web usage linked: \(summary)"
        case .linked: return "Web usage linked for this account."
        case .fallback(let detail): return "Web usage linked but unavailable: \(detail)"
        case .notLinked: return "Web usage not linked. Terminal usage fallback is active."
        }
    }

    // MARK: - Usage block

    @ViewBuilder
    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Manual-sign-in-required dominates the passive badge: it appears
            // only after a headless re-login concluded the web cookies are
            // also dead, so auto-recovery cannot proceed without the user.
            if recovery.manualSignInRequired(view.account.number) {
                manualLoginButton
            } else if view.credentialState == "needs_login" {
                credentialBadge
            }
            if let usage = view.usage {
                if let w = usage.fiveHour { UsageBar(label: "5h", window: w) }
                else                       { UnavailableBar(label: "5h") }
                if let w = usage.sevenDay  { UsageBar(label: "7d", window: w) }
                else                       { UnavailableBar(label: "7d") }
                if let err = view.error    { errorBadge(err) }
            } else if let err = view.error {
                errorBadge(err)
            } else {
                SkeletonBar(label: "5h")
                SkeletonBar(label: "7d")
            }
        }
        .padding(.leading, 32)
        .padding(.top, 2)
    }

    /// Actionable "Log in" affordance shown when automatic recovery has given
    /// up (web cookies dead). Opens the INTERACTIVE Quick re-login sheet so the
    /// user can type credentials. Disabled while any headless attempt is still
    /// in flight to avoid racing the coordinator's single-flight guard.
    private var manualLoginButton: some View {
        Button {
            quickRelogin.begin(for: view.account)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 9))
                Text("Log in")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange))
        }
        .buttonStyle(.plain)
        .disabled(recovery.isBusy)
        .opacity(recovery.isBusy ? 0.5 : 1)
        .help(view.credentialError ?? "Session expired — sign in to restore this account.")
    }

    private var credentialBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 9))
                .foregroundColor(.orange)
            Text("Needs login")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
                .lineLimit(1)
        }
        .help(view.credentialError ?? "Backup credentials cannot refresh.")
    }

    @ViewBuilder
    private func errorBadge(_ msg: String) -> some View {
        let isRateLimit = msg.contains("rate limited") || msg.contains("429")
        let friendly: String = {
            if isRateLimit { return msg.contains("retry in") ? msg : "Anthropic rate-limited · waiting" }
            if msg.contains("no credentials") { return "No credentials" }
            return "Couldn't fetch usage"
        }()
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9)).foregroundColor(.orange)
            Text(friendly)
                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            if isRateLimit {
                Button { webFallback.open(for: view) } label: {
                    Text("Open web usage")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor).underline()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }

    // MARK: - Swap logic

    private func trySwap() {
        guard !view.isActive else { return }
        // Backend safeToSwap is authoritative — it checks session status (busy/idle),
        // not just liveness. Idle VSCode sessions must not block a switch.
        if store.sessions?.safeToSwap == true {
            doSwap()
            return
        }
        // Fallback when backend data not yet loaded, or sessions are actually busy.
        let sessions = RunningSession.readAll()
        if sessions.isEmpty {
            doSwap()
            return
        }
        // Show NSAlert directly on the main thread (SwiftUI button actions
        // already run on the main thread — no DispatchQueue wrapper needed).
        let alert = NSAlert()
        alert.messageText = "Claude is busy"
        let lines = sessions
            .map { "• \($0.typeLabel): \($0.locationLabel)" }
            .joined(separator: "\n")
        alert.informativeText = "Switching to \(view.account.displayName) may interrupt:\n\(lines)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force switch")
        alert.addButton(withTitle: "Cancel")
        if PopoverModal.runAlert(alert) == .alertFirstButtonReturn {
            doSwap()
        }
    }

    private func doSwap() {
        let num = view.account.number
        Task { @MainActor in await store.swap(to: num) }
    }
}
