import AppKit
import SwiftUI

struct DiagnosticsTab: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var verifyCoordinator: VerifyCoordinator
    @EnvironmentObject var webFallback: WebFallbackCoordinator

    // Force-refresh local state (moved here from the popover header).
    @State private var isForceRefreshing = false
    @State private var forceRefreshOutcome: ForceRefreshOutcome? = nil
    @State private var forceRefreshCooldownActive = false
    private static let forceRefreshCooldownSec: Int = 10

    /// Top-level Settings tab: brings its own scroll surface and
    /// `SettingsPage` padding — no outer wrapper expected from a parent.
    var body: some View {
        ScrollView {
            SettingsPage {
                verifyGroup
                credentialRefreshGroup
                webUsageGroup
                logsGroup
            }
        }
    }

    private var verifyGroup: some View {
        SettingsGroup("Account verification", subtitle: "Checks the keychain backup, OAuth refresh, and Anthropic usage API for every managed account.") {
            Button {
                verifyCoordinator.begin()
            } label: {
                Label("Verify all accounts", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var credentialRefreshGroup: some View {
        SettingsGroup(
            "Credential refresh",
            subtitle: "Rotate OAuth tokens for inactive accounts now. Tokens are otherwise refreshed only when needed; only press this if you suspect a token has gone stale."
        ) {
            Button {
                runForceRefresh()
            } label: {
                if isForceRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Refreshing…")
                    }
                } else {
                    Label("Force refresh tokens now", systemImage: "key.fill")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isForceRefreshing || forceRefreshCooldownActive)

            if forceRefreshCooldownActive {
                Text("Recently refreshed — wait a few seconds before rotating again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let outcome = forceRefreshOutcome {
                Label(outcome.message, systemImage: outcome.iconName)
                    .font(.caption)
                    .foregroundColor(outcome.iconColor)
            }
        }
    }

    private func runForceRefresh() {
        guard !isForceRefreshing, !forceRefreshCooldownActive else { return }
        isForceRefreshing = true
        Task {
            var outcome: ForceRefreshOutcome = .success
            do {
                try await store.client.refreshAllTokens()
            } catch {
                let detail = error.localizedDescription
                if detail.localizedCaseInsensitiveContains("rate limited") {
                    outcome = .rateLimited(detail: detail)
                } else {
                    outcome = .error(detail: detail)
                }
            }
            await store.refreshNow()
            forceRefreshOutcome = outcome
            isForceRefreshing = false
            if outcome.triggerCooldown {
                forceRefreshCooldownActive = true
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.forceRefreshCooldownSec) * 1_000_000_000)
                    forceRefreshCooldownActive = false
                }
            }
        }
    }

    private var webUsageGroup: some View {
        SettingsGroup("Web usage diagnostics", subtitle: "Each account has its own embedded web profile, kept on this Mac only.") {
            keepAliveStatusRow
            if let accounts = store.snapshot?.accounts, !accounts.isEmpty {
                ForEach(accounts) { acc in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(acc.account.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(webFallback.state(for: acc.account).label)
                                .font(.caption)
                                .foregroundColor(webUsageColor(for: acc.account))
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(webFallback.isLinked(acc.account) ? "Open" : "Connect") {
                            webFallback.open(for: acc)
                        }
                        .controlSize(.small)
                        if webFallback.isLinked(acc.account) {
                            Button("Disconnect", role: .destructive) {
                                Task { await webFallback.disconnect(acc.account) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                Text("Add an account before linking web usage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func webUsageColor(for account: AccountDTO) -> Color {
        switch webFallback.state(for: account) {
        case .connected: return .green
        case .fallback: return .orange
        case .linked, .notLinked: return .secondary
        }
    }

    /// Shows when the keep-alive loop last ran and how many accounts it
    /// pinged in that tick. Lets users verify the safety net is alive
    /// without scrubbing through the diagnostics log file.
    @ViewBuilder
    private var keepAliveStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.circle")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cookie keep-alive")
                    .font(.system(size: 12, weight: .medium))
                Text(keepAliveDetailText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private var keepAliveDetailText: String {
        guard AppSettings.shared.cookieKeepAliveEnabled else {
            return "Disabled in Settings → Adaptive refresh. Cookies rely on normal polling only."
        }
        guard let last = webFallback.keepAliveLastTickAt else {
            return "First tick fires within ~5h of launch. No ping yet."
        }
        let ago = relativeShort(from: last)
        let pinged = webFallback.keepAliveLastPingedCount
        if pinged == 0 {
            return "Last tick \(ago) — every linked account was already fresh, nothing to ping."
        }
        return "Last tick \(ago) — pinged \(pinged) account\(pinged == 1 ? "" : "s") that had gone quiet."
    }

    /// Short human-readable "Xm ago" / "Xh ago" formatter scoped to this
    /// row. Avoids pulling in DateFormatter for a single label.
    private func relativeShort(from date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86_400)d ago"
    }

    // MARK: - Logs & diagnostics

    private var logsGroup: some View {
        SettingsGroup(
            "Logs & diagnostics",
            subtitle: "Logs and crash reports stay on your Mac unless you click Send. Stored under ~/Library/Logs/ClaudeBar/."
        ) {
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(DiagnosticsLogger.shared.logDirectory)
                } label: {
                    Label("Open log folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    let text = DiagnosticsLogger.shared.tail(lines: 200)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy last 200 lines", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Button {
                    sendDiagnosticsByMail()
                } label: {
                    Label("Send diagnostics…", systemImage: "envelope")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Opens the user's default mail client with a pre-filled message
    /// containing the last 200 log lines. Mail recipient is the project
    /// author. Privacy: user reviews + edits before sending.
    private func sendDiagnosticsByMail() {
        let log = DiagnosticsLogger.shared.tail(lines: 200)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let body = """
        App version: \(version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)

        --- Recent log (last 200 lines) ---
        \(log)
        """
        let subject = "\(AppInfo.displayName) diagnostics"
        let q: (String) -> String = { s in
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }
        let url = "mailto:nc.thanhngo@gmail.com?subject=\(q(subject))&body=\(q(body))"
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - Shared cosmetics used by diagnostics + restore sheets

struct SettingsBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
    }
}

enum SettingsRelativeDate {
    static func format(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
