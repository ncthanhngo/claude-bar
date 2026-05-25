import SwiftUI

// Outcome of a force-refresh attempt. Carries its own icon/title/cooldown
// decision so the popover view doesn't have to parse message strings.
enum ForceRefreshOutcome {
    case success
    case rateLimited(detail: String)
    case error(detail: String)

    var triggerCooldown: Bool {
        if case .success = self { return true }
        return false
    }

    var iconName: String {
        switch self {
        case .success:     return "checkmark.seal.fill"
        case .rateLimited: return "clock.badge.exclamationmark"
        case .error:       return "exclamationmark.triangle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .success:                return .green
        case .rateLimited, .error:    return .orange
        }
    }

    var title: String {
        switch self {
        case .success:     return "Credentials refreshed"
        case .rateLimited: return "Rate limited"
        case .error:       return "Refresh finished with errors"
        }
    }

    var message: String {
        switch self {
        case .success:
            return "Credentials refreshed for all inactive accounts."
        case .rateLimited(let detail):
            return "Rate limited by Anthropic — try again later. \(detail)"
        case .error(let detail):
            return "Some accounts failed to refresh: \(detail)"
        }
    }
}

struct MenuHeaderBar: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var briefingCoord: BriefingCoordinator
    @EnvironmentObject private var verifyCoordinator: VerifyCoordinator
    @ObservedObject private var settings = AppSettings.shared
    /// Footer is gone — Add account is the only header action that still
    /// needs to open a popover-hosted overlay, so the parent passes its
    /// state binding down as a closure.
    var onAddAccount: () -> Void = {}
    @State private var isHealthChecking = false
    @State private var isForceRefreshing = false
    @State private var healthResult: HealthCheckResult? = nil
    @State private var showHealthPopover = false
    @State private var forceRefreshOutcome: ForceRefreshOutcome? = nil
    @State private var showForceRefreshPopover = false
    @State private var forceRefreshCooldownActive = false

    private static let forceRefreshCooldownSec: UInt64 = 10

    private var isBusy: Bool {
        store.isRefreshing || isHealthChecking || isForceRefreshing
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(store.lastError == nil ? Color.secondary : Color.red)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            // Action cluster (right). Settings is the very last item so it
            // anchors the top-right corner per spec. Add account is tinted
            // accent so it visually carries the same "primary CTA" weight
            // it used to have as the only blue footer button.
            if isBusy {
                ProgressView().controlSize(.mini)
            }
            addAccountButton
            verifyAllButton
            healthCheckButton
            forceRefreshButton
            themeButton
            quitButton
            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Geometric center: status (left) and the action cluster (right) have
        // wildly different intrinsic widths, so two HStack Spacers around the
        // pill would drift it off-axis. Overlay pins the pill to the bar's
        // midpoint regardless of how long "Updated 12s ago" gets.
        .overlay(briefingButton)
    }

    // MARK: - Action buttons (header right cluster)

    private var addAccountButton: some View {
        Button(action: onAddAccount) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.borderless)
        .help("Add a Claude Code account")
        .pointingHandCursor()
        .accessibilityLabel("Add account")
    }

    private var verifyAllButton: some View {
        Button(action: { verifyCoordinator.begin() }) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Verify every account's credentials and web fallback")
        .pointingHandCursor()
        .accessibilityLabel("Verify all accounts")
    }

    private var themeButton: some View {
        Button(action: { settings.widgetTheme = settings.widgetTheme.next }) {
            themeIcon
        }
        .buttonStyle(.borderless)
        .help("Theme: \(settings.widgetTheme.rawValue) — click to cycle")
        .pointingHandCursor()
        .accessibilityLabel("Cycle theme")
    }

    @ViewBuilder private var themeIcon: some View {
        switch settings.widgetTheme {
        case .light:
            Image(systemName: "sun.max").font(.system(size: 12)).foregroundColor(.secondary)
        case .dark:
            Image(systemName: "moon").font(.system(size: 12)).foregroundColor(.secondary)
        case .apple:
            Image(systemName: "apple.logo").font(.system(size: 12)).foregroundColor(.secondary)
        case .rainbow:
            Circle()
                .fill(AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                    center: .center
                ))
                .frame(width: 12, height: 12)
        }
    }

    private var quitButton: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Image(systemName: "power")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Quit Claude Bar")
        .pointingHandCursor()
        .accessibilityLabel("Quit")
    }

    private var settingsButton: some View {
        Button(action: { SettingsWindowController.shared.show() }) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Open Settings")
        .pointingHandCursor()
        .accessibilityLabel("Settings")
    }

    private var briefingButton: some View {
        Button(action: { briefingCoord.show() }) {
            HStack(spacing: 4) {
                Image(systemName: "sun.haze")
                    .font(.system(size: 11))
                Text("Briefing")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        .help("Open Daily Briefing window")
        .pointingHandCursor()
        .accessibilityLabel("Open Daily Briefing")
    }

    private var forceRefreshButton: some View {
        Button(action: runForceRefresh) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundColor(forceRefreshCooldownActive ? .secondary.opacity(0.4) : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(forceRefreshCooldownActive)
        .help(forceRefreshCooldownActive
            ? "Recently refreshed — wait a few seconds before rotating again"
            : "Force refresh OAuth credentials (rotates refresh tokens for inactive accounts)")
        .pointingHandCursor()
        .popover(isPresented: $showForceRefreshPopover, arrowEdge: .bottom) {
            if let outcome = forceRefreshOutcome {
                ForceRefreshResultView(outcome: outcome, isPresented: $showForceRefreshPopover)
            }
        }
    }

    private var healthCheckButton: some View {
        Button(action: runHealthCheck) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Check account health (read-only — rotates only if a token is actually expired)")
        .pointingHandCursor()
        .popover(isPresented: $showHealthPopover, arrowEdge: .bottom) {
            if let result = healthResult {
                HealthCheckPopoverView(result: result, isPresented: $showHealthPopover)
            }
        }
    }

    private func runHealthCheck() {
        guard !isBusy else { return }
        showHealthPopover = false
        isHealthChecking = true
        Task {
            do {
                let report = try await store.client.verify()
                let failed = report.results.filter { !$0.swapReady }
                healthResult = failed.isEmpty ? .healthy(report.total) : .issues(failed: failed)
            } catch {
                healthResult = .failed(error.localizedDescription)
            }
            await store.refreshNow()
            isHealthChecking = false
            showHealthPopover = true
        }
    }

    private func runForceRefresh() {
        guard !isBusy, !forceRefreshCooldownActive else { return }
        showForceRefreshPopover = false
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
            showForceRefreshPopover = true
            if outcome.triggerCooldown {
                forceRefreshCooldownActive = true
                Task {
                    try? await Task.sleep(nanoseconds: Self.forceRefreshCooldownSec * 1_000_000_000)
                    forceRefreshCooldownActive = false
                }
            }
        }
    }

    private var statusDotColor: Color {
        if store.lastError != nil { return .red }
        if isBusy { return .orange }
        return .green
    }

    private var statusText: String {
        if isForceRefreshing { return "Refreshing credentials…" }
        if isHealthChecking { return "Checking health…" }
        if let err = store.lastError { return err }
        guard let when = store.lastRefreshAt else { return "Loading…" }
        let secs = max(0, Int(Date().timeIntervalSince(when)))
        if secs < 5  { return "Updated just now" }
        if secs < 60 { return "Updated \(secs)s ago" }
        return "Updated \(secs / 60)m ago"
    }
}

private struct ForceRefreshResultView: View {
    let outcome: ForceRefreshOutcome
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: outcome.iconName).foregroundColor(outcome.iconColor)
                Text(outcome.title).font(.system(size: 12, weight: .semibold))
            }
            Text(outcome.message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
