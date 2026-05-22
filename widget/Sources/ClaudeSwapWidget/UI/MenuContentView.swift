import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var loginCoordinator: LoginCoordinator
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuHeaderBar()
            Divider().opacity(0.5)
            SectionHeaderView(title: "Accounts",
                              trailing: store.snapshot.map { "\($0.accounts.count)" },
                              color: settings.widgetTheme.sectionHeaderColor)
            AccountListSection()
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
    }
}

// MARK: - Account list

struct AccountListSection: View {
    @EnvironmentObject var store: AppStore

    private static let scrollThreshold = 6

    var body: some View {
        if let snap = store.snapshot, !snap.accounts.isEmpty {
            let sorted = snap.accounts.sorted { $0.isActive && !$1.isActive }
            let needsScroll = sorted.count > Self.scrollThreshold
            let rows = VStack(alignment: .leading, spacing: 3) {
                ForEach(sorted) { acc in
                    AccountRowView(view: acc, onRename: { promptRename(for: acc) })
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

    private func promptRename(for acc: AccountViewDTO) {
        AccountRenamePrompt.run(for: acc) { newName in
            Task { await store.rename(acc.account.number, to: newName) }
        }
    }
}

struct EmptyAccountsView: View {
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

struct AutoSwapSection: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: $settings.autoSwapEnabled)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                Text(statusLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)
                if let sess = store.sessions {
                    sessionsBadge(sess)
                }
                Spacer()
            }
            ThresholdSliderView(
                threshold: $settings.thresholdPct,
                currentPct: currentActivePct,
                isEnabled: settings.autoSwapEnabled && isOperational
            )
            if settings.autoSwapEnabled && !isOperational {
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 10)).foregroundColor(UsagePalette.color(for: 70))
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
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(sess.safeToSwap
                ? UsagePalette.color(for: 40).opacity(0.12)
                : UsagePalette.color(for: 70).opacity(0.15))
        )
        .foregroundColor(sess.safeToSwap
            ? UsagePalette.color(for: 40)
            : UsagePalette.color(for: 70))
    }
}

// MARK: - Footer

struct FooterActions: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var briefingCoord: BriefingCoordinator

    @ViewBuilder private var themeIcon: some View {
        switch settings.widgetTheme {
        case .light:
            Image(systemName: "sun.max").font(.system(size: 13)).foregroundColor(.secondary)
        case .dark:
            Image(systemName: "moon").font(.system(size: 13)).foregroundColor(.secondary)
        case .apple:
            Image(systemName: "apple.logo").font(.system(size: 13)).foregroundColor(.secondary)
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
        HStack(spacing: 22) {
            footerButton(
                label: "Daily",
                help: "Open Daily Briefing window",
                action: { briefingCoord.show() }
            ) {
                Image(systemName: "sun.haze")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            footerButton(
                label: "Theme",
                help: "Theme: \(settings.widgetTheme.rawValue) — click to cycle",
                action: { settings.widgetTheme = settings.widgetTheme.next }
            ) {
                themeIcon
            }

            footerButton(
                label: "Quit",
                help: "Quit Claude Bar",
                action: { NSApplication.shared.terminate(nil) }
            ) {
                Image(systemName: "power")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func footerButton<Icon: View>(
        label: String,
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                icon()
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .pointingHandCursor()
    }
}

