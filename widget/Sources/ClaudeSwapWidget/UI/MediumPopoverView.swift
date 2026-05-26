import SwiftUI

/// Medium popover layout — 2/3-scaled compact version of Standard.
///
/// Follows `plans/visuals/popover-size-2-3-preview.html`:
///   • Width 293 (≈ 0.667 × 440)
///   • Heights scaled: 0/1/2/3+ accounts → 347 / 380 / 443 / 506
///   • shellHeight 317, rowHeight 63 (vs Standard's 475 / 95)
///
/// Same sections as Standard (accounts with usage bars, auto-swap, token
/// usage) but each rendered as a tight KPI card instead of the full
/// dashboard. The bottom auto-swap / token cards collapse to one line + a
/// 2-column KPI grid, dropping the threshold slider and chart entirely.
///
/// Tap an account row to swap — same handler as Standard. Auto-swap and
/// token cards are read-only; deep edits go through Settings or the
/// Standard layout. For the smallest layout (no auto-swap / token cards
/// at all) see TinyPopoverView.
struct MediumPopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var updateController: UpdateController
    @ObservedObject private var settings = AppSettings.shared

    private static let popoverWidth: CGFloat = 293
    private static let shellHeight: CGFloat = 317
    private static let rowHeight: CGFloat = 63

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MenuHeaderBar()
                    .padding(.top, 4)
                Divider().opacity(0.5)
                ScrollView(.vertical, showsIndicators: false) {
                    mainBody
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.popoverWidth, height: popoverHeight)
        .animation(.easeInOut(duration: 0.18), value: popoverHeight)
        .background(popoverBackground)
        .background(WindowAppearanceSetter(theme: settings.widgetTheme))
        .background(PopoverWindowCapture())
        .overlay(UpdateOverlayView(driver: updateController.driver))
        .overlay { SwapErrorOverlay() }
        .focusable()
        .focusEffectDisabled()
    }

    private var popoverHeight: CGFloat {
        let count = store.snapshot?.accounts.count ?? 0
        switch count {
        case 0:      return 347
        case 1:      return Self.shellHeight + Self.rowHeight        // 380
        case 2:      return Self.shellHeight + Self.rowHeight * 2    // 443
        default:     return Self.shellHeight + Self.rowHeight * 3    // 506
        }
    }

    @ViewBuilder
    private var popoverBackground: some View {
        if settings.widgetTheme.useVibrancy {
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
        } else {
            settings.widgetTheme.background
        }
    }

    @ViewBuilder
    private var mainBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            accountsHeader
            if let snap = store.snapshot, !snap.accounts.isEmpty {
                let sorted = snap.accounts.sorted { $0.isActive && !$1.isActive }
                let visible = Array(sorted.prefix(3))
                VStack(spacing: 4) {
                    ForEach(visible) { acc in
                        MediumAccountRow(view: acc)
                    }
                    if sorted.count > visible.count {
                        ScrollView { extraRows(Array(sorted.dropFirst(visible.count))) }
                            .frame(maxHeight: Self.rowHeight * 2)
                    }
                }
                .padding(.horizontal, 6)
            } else {
                EmptyAccountsView().padding(.top, 12)
            }
            sectionTitle("Auto-swap").padding(.top, 6)
            MediumAutoSwapCard()
            sectionTitle("Token usage").padding(.top, 6)
            MediumTokenUsageCard()
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func extraRows(_ accounts: [AccountViewDTO]) -> some View {
        VStack(spacing: 4) {
            ForEach(accounts) { acc in
                MediumAccountRow(view: acc)
            }
        }
    }

    private var accountsHeader: some View {
        HStack {
            Text("Accounts")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            Spacer()
            if let count = store.snapshot.map({ "\($0.accounts.count)" }) {
                Text(count)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
    }
}

// MARK: - Account row

/// Compact account row for the Minimum layout: avatar 28 + email +
/// twin 5h / 7d usage bars. ~63pt tall (vs 95pt in Standard). Tap the
/// row to swap — no separate Switch button, no overflow menu.
private struct MediumAccountRow: View {
    let view: AccountViewDTO
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovering = false

    var body: some View {
        Button {
            guard !view.isActive, store.swappingTo == nil else { return }
            Task { @MainActor in await store.swap(to: view.account.number) }
        } label: {
            HStack(spacing: 8) {
                AvatarView(
                    initial: view.account.initial,
                    seed: view.account.email + (view.account.organizationUuid ?? ""),
                    size: 28
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(view.account.displayName)
                            .font(.system(size: 11, weight: view.isActive ? .semibold : .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if view.isActive {
                            Circle()
                                .fill(settings.widgetTheme.activeAccent)
                                .frame(width: 7, height: 7)
                        }
                        Spacer(minLength: 4)
                        if store.swappingTo == view.account.number {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    bars
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor(when: !view.isActive)
        .allowsHitTesting(store.swappingTo == nil)
        .onHover { isHovering = $0 }
    }

    private var bars: some View {
        HStack(spacing: 5) {
            usageBar(view.usage?.fiveHour?.percentInt)
            usageBar(view.usage?.sevenDay?.percentInt)
        }
        .frame(height: 5)
    }

    @ViewBuilder
    private func usageBar(_ pct: Int?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if let pct {
                    Capsule()
                        .fill(UsagePalette.color(for: pct))
                        .frame(width: geo.size.width * CGFloat(max(0, min(100, pct))) / 100)
                }
            }
        }
        .frame(height: 5)
    }

    private var rowBackground: Color {
        if view.isActive { return settings.widgetTheme.activeAccent.opacity(0.10) }
        if isHovering    { return Color.primary.opacity(0.06) }
        return Color.primary.opacity(0.03)
    }
}

// MARK: - Auto-swap card

/// One-line summary + 2-column KPI grid. Read-only — to change the
/// threshold or toggle auto-swap, open the Standard layout or Settings.
private struct MediumAutoSwapCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Threshold")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("\(settings.thresholdPct)%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                Text("·")
                    .foregroundColor(.secondary)
                Text(statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(statusColor)
                Spacer()
            }
            HStack(spacing: 10) {
                kpi("Current", value: currentText, color: currentColor)
                Divider().frame(height: 26)
                kpi("Next eligible", value: nextEligibleText, color: .primary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 6)
    }

    private func kpi(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLabel: String {
        if !settings.autoSwapEnabled { return "Disabled" }
        return store.snapshot?.active?.usage?.fiveHour?.percentInt != nil ? "Enabled" : "Paused"
    }

    private var statusColor: Color {
        if !settings.autoSwapEnabled { return .secondary }
        return store.snapshot?.active?.usage?.fiveHour?.percentInt != nil ? .green : .orange
    }

    private var currentText: String {
        guard let pct = store.snapshot?.active?.usage?.fiveHour?.percentInt else { return "—" }
        return "\(pct)%"
    }

    private var currentColor: Color {
        guard let pct = store.snapshot?.active?.usage?.fiveHour?.percentInt else { return .secondary }
        return UsagePalette.color(for: pct)
    }

    /// Cheapest inactive candidate by 5h usage — same heuristic the
    /// auto-swap picker uses. Surfaces who Claude Bar will hand control to
    /// if the active account crosses the threshold right now.
    private var nextEligibleText: String {
        guard let accounts = store.snapshot?.accounts else { return "—" }
        let candidates = accounts
            .filter { !$0.isActive }
            .compactMap { acc -> (String, Int)? in
                guard let pct = acc.usage?.fiveHour?.percentInt else { return nil }
                return (acc.account.displayName, pct)
            }
            .sorted { $0.1 < $1.1 }
        return candidates.first?.0 ?? "—"
    }
}

// MARK: - Token usage card

/// Today total · cost on the header line, then a 2-column KPI for 7d /
/// month. Pulls from `store.tokenStats` which the Standard chart also
/// uses, so the numbers stay in lock-step.
private struct MediumTokenUsageCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Today")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(headlineText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 10) {
                kpi("7 days", value: weekText)
                Divider().frame(height: 26)
                kpi("Month", value: monthText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 6)
    }

    private func kpi(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headlineText: String {
        guard let s = store.tokenStats else { return "—" }
        let tokens = Self.compactTokens(s.today.totalTokens)
        let cost = String(format: "$%.2f", s.today.estimatedCostUsd)
        return "\(tokens) · \(cost)"
    }

    private var weekText: String {
        guard let s = store.tokenStats else { return "—" }
        return Self.compactTokens(s.thisWeek.totalTokens)
    }

    private var monthText: String {
        guard let s = store.tokenStats else { return "—" }
        return Self.compactTokens(s.thisMonth.totalTokens)
    }

    /// 14_300_000 → "14.3M". The mock uses this same compact form so the
    /// popover stays readable at 293pt width even when totals balloon.
    static func compactTokens(_ n: Int64) -> String {
        let v = Double(n)
        switch v {
        case ..<1_000:          return "\(n)"
        case ..<1_000_000:      return String(format: "%.1fK", v / 1_000)
        case ..<1_000_000_000:  return String(format: "%.1fM", v / 1_000_000)
        default:                return String(format: "%.2fB", v / 1_000_000_000)
        }
    }
}
