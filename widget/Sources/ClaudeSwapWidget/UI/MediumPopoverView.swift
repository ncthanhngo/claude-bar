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
    // Row content measures: VStack with name line (~16) + two stacked
    // usage rows (~14 each + 4 spacing) ≈ 48; outer padding 6×2 = 12.
    // Total ≈ 60. We keep 62 for a small safety buffer; the old 78pt
    // budget left a visible 16pt gap below the last visible row.
    private static let rowHeight: CGFloat = 62
    // Shell = header (36) + divider (1) + accounts header (22) +
    // divider (1) + auto-swap section title (22) + MediumAutoSwapCard
    // (~134) + Day/Week/Month strip (~46) + outer padding (8) = ~270.
    // Was 336 — over-budget by ~65pt because the old layout had a
    // full Token-usage card with section title + chrome; this release
    // collapses it to the same Day/Week/Month strip Tiny uses.
    private static let shellHeight: CGFloat = 270
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

    /// Always-visible footer. Auto-swap card on top (slider + KPI),
    /// then a divider, then the Tiny-style Day / Week / Month token
    /// strip — the previous boxed token card was nearly as tall as the
    /// auto-swap controls and added 80+pt of redundant chrome with
    /// "Today" / "7 days" / "Month" labels duplicating their own
    /// section title. The strip carries those labels inline so the
    /// title row goes away entirely.
    private var bottomFixedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Auto-swap").padding(.top, 4)
            MediumAutoSwapCard()
            Divider().opacity(0.4).padding(.top, 4)
            MediumTokenStrip()
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        }
        .padding(.bottom, 6)
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

// MARK: - Token usage strip

/// Compact three-column Day / Week / Month token-usage strip — same
/// design Tiny uses so the two layouts read identically when the user
/// switches between them. Replaces the older boxed `MediumTokenUsageCard`
/// (Today + cost + 7d + Month grid) which doubled the height for what is
/// effectively three KPI numbers. Cost column was dropped — users who
/// need cost open the Full layout's token chart with its rate-table.
private struct MediumTokenStrip: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            column("Day", value: dayText)
            Divider().frame(height: 24).opacity(0.4)
            column("Week", value: weekText)
            Divider().frame(height: 24).opacity(0.4)
            column("Month", value: monthText)
        }
    }

    private func column(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var dayText: String {
        guard let s = store.tokenStats else { return "—" }
        return compactTokens(s.today.totalTokens)
    }

    private var weekText: String {
        guard let s = store.tokenStats else { return "—" }
        return compactTokens(s.thisWeek.totalTokens)
    }

    private var monthText: String {
        guard let s = store.tokenStats else { return "—" }
        return compactTokens(s.thisMonth.totalTokens)
    }

    /// 14_300_000 → "14.3M". Same helper Tiny uses; kept local here so
    /// the two layouts don't share an arbitrary cross-file dependency.
    private func compactTokens(_ n: Int64) -> String {
        let v = Double(n)
        switch v {
        case ..<1_000:         return "\(n)"
        case ..<1_000_000:     return String(format: "%.1fK", v / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", v / 1_000_000)
        default:               return String(format: "%.2fB", v / 1_000_000_000)
        }
    }
}
