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

    private static let popoverWidth: CGFloat = 300
    // Empirically-measured row height for one MediumAccountRow: avatar
    // 28 + name line ~16 + 2 stacked usage rows (5h + 7d) ~36 + 12pt
    // vertical padding ≈ 78pt. The old 66 underestimated this since
    // the rewrite that replaced twin 5pt bars with full labelled "X%"
    // rows — popovers with 3 accounts ended up scrolling because the
    // computed height was too small.
    private static let rowHeight: CGFloat = 78
    // The non-scrolling shell — header + accounts section title +
    // auto-swap card + token card + paddings. Re-measured against the
    // current rendered layout: header 36, accounts header 24, two
    // section titles 22 × 2, auto-swap card 132, token card 82,
    // outer paddings 18 = ~336pt. Used to cap the popover frame so
    // overflow ONLY hits the account list, never the bottom cards.
    private static let shellHeight: CGFloat = 336
    /// The most accounts shown at full row height. Anything past this
    /// scrolls inside the account list — the auto-swap + token cards
    /// below stay anchored regardless. Matches the user's request:
    /// "≤ 3 accounts: no scroll; > 3: scroll only the account section".
    private static let accountsRowsBeforeScroll = 3

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MenuHeaderBar()
                    .padding(.top, 4)
                Divider().opacity(0.5)
                accountsHeader
                accountsSection
                Divider().opacity(0.4)
                bottomFixedSection
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
        Self.shellHeight + visibleAccountsHeight
    }

    /// Height the account list actually consumes — at most three rows;
    /// anything beyond scrolls inside. Used by `popoverHeight` to grow
    /// the frame for 1/2/3 accounts and to cap it at the 3-row size for
    /// 4+ accounts (the user's stated cutoff).
    private var visibleAccountsHeight: CGFloat {
        let count = store.snapshot?.accounts.count ?? 0
        if count == 0 { return 0 }
        let visible = min(count, Self.accountsRowsBeforeScroll)
        // Inter-row spacing 4pt × (visible - 1) + 4 vertical padding on
        // the wrapping VStack.
        return CGFloat(visible) * Self.rowHeight + CGFloat(max(0, visible - 1)) * 4 + 8
    }

    @ViewBuilder
    private var popoverBackground: some View {
        if settings.widgetTheme.useVibrancy {
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
        } else {
            settings.widgetTheme.background
        }
    }

    /// Account list. Sized to exactly the visible-rows height so the
    /// frame doesn't reserve extra space when fewer than 3 accounts
    /// exist. Wraps in ScrollView only when there's overflow — the
    /// auto-swap + token cards below remain pinned regardless.
    @ViewBuilder
    private var accountsSection: some View {
        if let snap = store.snapshot, !snap.accounts.isEmpty {
            let sorted = snap.accounts.sorted { $0.isActive && !$1.isActive }
            let hasOverflow = sorted.count > Self.accountsRowsBeforeScroll
            ScrollView(.vertical, showsIndicators: hasOverflow) {
                VStack(spacing: 4) {
                    ForEach(sorted) { acc in
                        MediumAccountRow(view: acc)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .frame(height: visibleAccountsHeight)
            .scrollDisabled(!hasOverflow)
        } else {
            EmptyAccountsView()
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
        }
    }

    /// Always-visible footer with the Auto-swap and Token-usage cards.
    /// Lives outside any ScrollView so users can drag the threshold
    /// slider and read token totals even when the account list above is
    /// scrolling. Padding mirrors the previous mainBody so spacing
    /// across both halves looks unified.
    private var bottomFixedSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Auto-swap").padding(.top, 6)
            MediumAutoSwapCard()
            sectionTitle("Token usage").padding(.top, 6)
            MediumTokenUsageCard()
        }
        .padding(.bottom, 8)
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
                            .font(.system(size: 12, weight: view.isActive ? .semibold : .regular))
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
                    usageRow(label: "5h", pct: view.usage?.fiveHour?.percentInt)
                    usageRow(label: "7d", pct: view.usage?.sevenDay?.percentInt)
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

    /// Per-window usage line: `"5h" label · color-coded bar · readable %`.
    /// The old design rendered just two 5pt-tall bars side-by-side which
    /// was unreadable — width alone doesn't communicate the value. Now
    /// the percentage is spelled out in monospaced digits next to a 6pt
    /// bar, with palette colour tinting both the bar fill and the %.
    private func usageRow(label: String, pct: Int?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .leading)
            usageBar(pct).frame(height: 6)
            Text(pct.map { "\($0)%" } ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(pct == nil ? .secondary : UsagePalette.percentText)
                .frame(width: 34, alignment: .trailing)
        }
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

/// Editable auto-swap controls — toggle + threshold slider + KPI grid.
/// Mirrors the Full layout's `AutoSwapSection` semantics so the popover
/// is functionally complete even at Standard size: the user can flip
/// auto-swap on/off and drag the threshold from inside this card without
/// opening Settings or switching to Full.
private struct MediumAutoSwapCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PointingHandSwitch(isOn: $settings.autoSwapEnabled, accessibilityName: "Auto-swap")
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                Spacer()
            }
            ThresholdSliderView(
                threshold: $settings.thresholdPct,
                currentPct: store.snapshot?.active?.usage?.fiveHour?.percentInt,
                isEnabled: settings.autoSwapEnabled
            )
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
