import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var loginCoordinator: LoginCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @State private var renamingAccount: AccountViewDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar()
            Divider().opacity(0.5)
            SectionHeaderView(title: "Accounts",
                              trailing: store.snapshot.map { "\($0.accounts.count)" },
                              color: settings.widgetTheme.sectionHeaderColor)
            AccountListSection(renaming: $renamingAccount)
            Divider().opacity(0.5).padding(.top, 4)
            SectionHeaderView(title: "Auto-swap",
                              color: settings.widgetTheme.sectionHeaderColor)
            AutoSwapSection()
            Divider().opacity(0.5).padding(.top, 6)
            FooterActions()
        }
        .padding(.vertical, 6)
        .background(settings.widgetTheme.background)
        .background(WindowAppearanceSetter(theme: settings.widgetTheme))
        .sheet(item: $renamingAccount) { acc in
            RenameAccountSheet(account: acc) { newName in
                Task { await store.rename(acc.account.number, to: newName) }
            }
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @EnvironmentObject var store: AppStore
    @State private var isHealthChecking = false
    @State private var healthResult: HealthCheckResult? = nil
    @State private var showHealthPopover = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(store.lastError == nil ? Color.secondary : Color.red)
                .lineLimit(1)
            Spacer()
            if store.isRefreshing || isHealthChecking {
                ProgressView().controlSize(.mini)
            } else {
                Button(action: runHealthCheck) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Check account health & refresh credentials")
                .pointingHandCursor()
                .popover(isPresented: $showHealthPopover, arrowEdge: .bottom) {
                    if let result = healthResult {
                        HealthCheckPopoverView(result: result, isPresented: $showHealthPopover)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func runHealthCheck() {
        guard !isHealthChecking && !store.isRefreshing else { return }
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

    private var statusDotColor: Color {
        if store.lastError != nil { return .red }
        if store.isRefreshing || isHealthChecking { return .orange }
        return .green
    }

    private var statusText: String {
        if isHealthChecking { return "Checking health…" }
        if let err = store.lastError { return err }
        guard let when = store.lastRefreshAt else { return "Loading…" }
        let secs = max(0, Int(Date().timeIntervalSince(when)))
        if secs < 5  { return "Updated just now" }
        if secs < 60 { return "Updated \(secs)s ago" }
        return "Updated \(secs / 60)m ago"
    }
}

// MARK: - Account list

private struct AccountListSection: View {
    @EnvironmentObject var store: AppStore
    @Binding var renaming: AccountViewDTO?

    private static let scrollThreshold = 6

    var body: some View {
        if let snap = store.snapshot, !snap.accounts.isEmpty {
            let sorted = snap.accounts.sorted { $0.isActive && !$1.isActive }
            let needsScroll = sorted.count > Self.scrollThreshold
            let rows = VStack(alignment: .leading, spacing: 3) {
                ForEach(sorted) { acc in
                    AccountRowView(view: acc, onRename: { renaming = acc })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            if needsScroll {
                ScrollView { rows }.frame(maxHeight: 580)
            } else {
                rows
            }
        } else {
            EmptyAccountsView()
        }
    }
}

private struct EmptyAccountsView: View {
    @EnvironmentObject var loginCoordinator: LoginCoordinator

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No accounts yet")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Add your first account") { loginCoordinator.begin() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Auto-swap

private struct AutoSwapSection: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: $settings.autoSwapEnabled)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                Text(statusLabel)
                    .font(.callout)
                    .foregroundColor(statusColor)
                Spacer()
                if let sess = store.sessions {
                    sessionsBadge(sess)
                }
            }
            ThresholdSliderView(
                threshold: $settings.thresholdPct,
                currentPct: currentActivePct,
                isEnabled: settings.autoSwapEnabled && isOperational
            )
            if settings.autoSwapEnabled && !isOperational {
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 10)).foregroundColor(.orange)
                    Text("Paused — no usage data. Will resume when fetch succeeds.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var isOperational: Bool { currentActivePct != nil }

    private var statusLabel: String {
        if !settings.autoSwapEnabled { return "Disabled" }
        return isOperational ? "Enabled" : "Paused"
    }

    private var statusColor: Color {
        if !settings.autoSwapEnabled { return .secondary }
        return isOperational ? .primary : .orange
    }

    private var currentActivePct: Int? {
        store.snapshot?.active?.usage?.fiveHour?.percentInt
    }

    private func sessionsBadge(_ sess: SessionReportDTO) -> some View {
        HStack(spacing: 4) {
            Image(systemName: sess.safeToSwap
                  ? "checkmark.shield.fill"
                  : "exclamationmark.shield.fill")
                .font(.system(size: 10))
            Text(sess.safeToSwap ? "Safe" : "claude busy")
                .font(.system(size: 10))
        }
        .foregroundColor(sess.safeToSwap ? .green : .orange)
    }
}

// MARK: - Footer

private struct FooterActions: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var briefingCoord: BriefingCoordinator

    @ViewBuilder private var themeIcon: some View {
        switch settings.widgetTheme {
        case .light:
            Image(systemName: "sun.max").font(.system(size: 13)).foregroundColor(.secondary)
        case .dark:
            Image(systemName: "moon").font(.system(size: 13)).foregroundColor(.secondary)
        case .rainbow:
            Circle()
                .fill(AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                    center: .center
                ))
                .frame(width: 14, height: 14)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless).help("Settings")
            .pointingHandCursor()

            Button {
                briefingCoord.show()
            } label: {
                Image(systemName: "sun.haze")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless).help("Mở Daily Briefing")
            .pointingHandCursor()

            Spacer()

            Button {
                settings.widgetTheme = settings.widgetTheme.next
            } label: {
                themeIcon
            }
            .buttonStyle(.borderless)
            .help("Theme: \(settings.widgetTheme.rawValue) — click to cycle")
            .pointingHandCursor()

            Spacer()

            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless).help("Quit")
            .pointingHandCursor()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

