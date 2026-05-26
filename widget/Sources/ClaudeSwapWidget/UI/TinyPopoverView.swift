import SwiftUI

/// Tiny popover layout — smallest surface the app ships.
///
/// Header bar + account list, nothing else. No section title, no auto-swap
/// card, no token card, no usage bars. Each row carries just enough to be
/// useful at a glance:
///   • Avatar
///   • Display name
///   • Two tiny "5h" / "7d" percentage chips with traffic-light colour
///   • ACTIVE dot for the live account
///
/// The chips are colour-coded with `UsagePalette` so even at this size the
/// user reads quota at a glance without enlarging the popover. Tap any row
/// to swap.
struct TinyPopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var updateController: UpdateController
    @ObservedObject private var settings = AppSettings.shared

    // Width measured against the two largest in-row elements: avatar 22pt +
    // name area (truncates at ~80pt) + two 5h/7d chips (each ~52pt with
    // 13pt monospaced value + padding) + ACTIVE dot 8pt + 4× 10pt
    // horizontal paddings. 227pt — the v10.43 value — squeezed the chip
    // text onto multiple lines because 13pt "0%" wrapped. 290pt restores
    // single-line chips and leaves the row compact without re-introducing
    // the wide-Standard look.
    private static let popoverWidth: CGFloat = 290
    // Real measured height of one TinyAccountRow: avatar 22 + 7pt vertical
    // padding × 2 = 36pt; tightened from the previous 46 because the
    // previous estimate over-budgeted the row and left visible slack
    // inside the bounded ScrollView below the last row.
    private static let rowHeight: CGFloat = 38
    // Shell = header (32) + divider (1) + token strip (10pt padding +
    // 30pt content = 40) + divider (1) + auto-swap (12pt padding +
    // ~84pt slider+toggle+legend = 96) = ~170.
    private static let shellHeight: CGFloat = 170
    /// Max account rows shown at full height before the in-list scroll
    /// engages. Picked low for Tiny because the layout's whole point is
    /// to stay short — past 4 rows the user should be on Standard / Full.
    private static let accountsRowsBeforeScroll = 4

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MenuHeaderBar()
                    .padding(.top, 4)
                Divider().opacity(0.5)
                accountsSection
                Divider().opacity(0.4)
                TinyTokenUsageStrip()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                Divider().opacity(0.4)
                TinyAutoSwapBar()
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
                    .padding(.bottom, 5)
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

    /// Bounded ScrollView around the account list — height computed
    /// exactly from rowHeight × visible-rows so no slack leaks below
    /// the last row. Replaces the previous `maxHeight: .infinity`
    /// frame that let the ScrollView absorb every spare pixel of
    /// vertical space, leaving an unwanted blank strip above the
    /// token-usage divider.
    @ViewBuilder
    private var accountsSection: some View {
        if let snap = store.snapshot, !snap.accounts.isEmpty {
            let sorted = snap.accounts.sorted { $0.isActive && !$1.isActive }
            let hasOverflow = sorted.count > Self.accountsRowsBeforeScroll
            ScrollView(.vertical, showsIndicators: hasOverflow) {
                VStack(spacing: 2) {
                    ForEach(sorted) { acc in
                        TinyAccountRow(view: acc, onRename: { promptRename(for: acc) })
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .frame(height: visibleAccountsHeight)
            .scrollDisabled(!hasOverflow)
        } else {
            EmptyAccountsView()
                .padding(.top, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 90)
        }
    }

    /// Pixel-exact height for `min(count, accountsRowsBeforeScroll)`
    /// rows + inter-row spacing + the VStack's 4pt top/bottom padding.
    /// Empty state has its own 90pt slot via accountsSection so the
    /// popover doesn't go full-tall when no accounts exist yet.
    private var visibleAccountsHeight: CGFloat {
        let count = store.snapshot?.accounts.count ?? 0
        if count == 0 { return 90 }
        let visible = min(count, Self.accountsRowsBeforeScroll)
        return CGFloat(visible) * Self.rowHeight + CGFloat(max(0, visible - 1)) * 2 + 8
    }

    private var popoverHeight: CGFloat {
        Self.shellHeight + visibleAccountsHeight
    }

    private func promptRename(for acc: AccountViewDTO) {
        let num = acc.account.number
        let storeRef = store
        RenameAccountCoordinator.shared.present(for: acc) { newName in
            Task { await storeRef.rename(num, to: newName) }
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

}

/// Stripped-down account row. The two `UsageChip`s are the only quota
/// surface — they replace the full usage bars from Standard/Medium with
/// a tiny "5h X%" / "7d Y%" pill each.
private struct TinyAccountRow: View {
    let view: AccountViewDTO
    let onRename: () -> Void
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovering = false

    var body: some View {
        Button {
            guard !view.isActive, store.swappingTo == nil else { return }
            Task { @MainActor in await store.swap(to: view.account.number) }
        } label: {
            HStack(spacing: 10) {
                AvatarView(
                    initial: view.account.initial,
                    seed: view.account.email + (view.account.organizationUuid ?? ""),
                    size: 22
                )
                Text(view.account.displayName)
                    .font(.system(size: 13, weight: view.isActive ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                UsageChip(label: "5h", pct: view.usage?.fiveHour?.percentInt)
                UsageChip(label: "7d", pct: view.usage?.sevenDay?.percentInt)
                trailing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor(when: !view.isActive)
        .allowsHitTesting(store.swappingTo == nil)
        .onHover { isHovering = $0 }
        .contextMenu { AccountActionMenu(view: view, onRename: onRename) }
    }

    @ViewBuilder
    private var trailing: some View {
        if store.swappingTo == view.account.number {
            ProgressView().controlSize(.mini)
        } else if view.isActive {
            Circle()
                .fill(settings.widgetTheme.activeAccent)
                .frame(width: 8, height: 8)
        } else {
            // Placeholder keeps the trailing edge aligned with the active
            // row's dot so chips don't jitter horizontally as rows differ.
            Circle().fill(Color.clear).frame(width: 8, height: 8)
        }
    }

    private var rowBackground: Color {
        if view.isActive { return settings.widgetTheme.activeAccent.opacity(0.12) }
        if isHovering    { return Color.primary.opacity(0.06) }
        return .clear
    }
}

/// Compact "5h 42%" / "7d 78%" pill. Background tint comes from
/// `UsagePalette` so the chip itself encodes the quota tier at a glance —
/// no need for a separate icon or threshold annotation in this layout.
private struct UsageChip: View {
    let label: String
    let pct: Int?

    var body: some View {
        // Fixed widths on both inner Text cells so chips render at
        // the same total width whether the value is "0%", "10%", or
        // "100%". Without these, the chip pair in a row with "0%"
        // values sat further right than a row with "10%" values, and
        // the right edge of the popover zig-zagged. Label slot 14pt
        // (fits "5h" / "7d"); value slot 30pt (fits "100%" monospaced).
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .leading)
            Text(valueText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(valueColor)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(background))
        .overlay(Capsule().stroke(palette.opacity(0.30), lineWidth: 0.6))
    }

    private var valueColor: Color { pct == nil ? .secondary : UsagePalette.percentText }

    private var valueText: String {
        guard let p = pct else { return "—" }
        return "\(p)%"
    }

    private var palette: Color {
        guard let p = pct else { return .secondary }
        return UsagePalette.color(for: p)
    }

    private var background: Color { palette.opacity(0.16) }
}

/// Compact auto-swap controls at the bottom of the Tiny popover. Same
/// data path as Full / Standard — `settings.autoSwapEnabled` +
/// `settings.thresholdPct` — but rendered as a single tight strip so the
/// user can flip auto-swap on/off and drag the threshold without leaving
/// the smallest layout. The slider's traffic-light current marker and
/// trigger legend stay visible at this width because they were sized
/// against a 320pt-wide rail to begin with.
private struct TinyAutoSwapBar: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PointingHandSwitch(isOn: $settings.autoSwapEnabled, accessibilityName: "Auto-swap")
                Text("Auto-swap")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.78))
                Text(statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(statusColor)
                Spacer()
            }
            ThresholdSliderView(
                threshold: $settings.thresholdPct,
                currentPct: store.snapshot?.active?.usage?.fiveHour?.percentInt,
                isEnabled: settings.autoSwapEnabled
            )
        }
    }

    private var statusLabel: String {
        if !settings.autoSwapEnabled { return "off" }
        return store.snapshot?.active?.usage?.fiveHour?.percentInt != nil ? "on" : "paused"
    }

    private var statusColor: Color {
        if !settings.autoSwapEnabled { return .secondary }
        return store.snapshot?.active?.usage?.fiveHour?.percentInt != nil ? .green : .orange
    }
}

/// Three-column token-usage summary that fills the previously-empty
/// strip between the account list and the auto-swap bar. Matches the
/// Standard layout's MediumTokenUsageCard but at half the height: just
/// the headline "X tokens" per period, no cost column, no labels in a
/// separate row. Pulled from `store.tokenStats` (same data source as
/// the Full layout's chart) so numbers stay consistent.
private struct TinyTokenUsageStrip: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            column("Day", value: dayText)
            Divider().frame(height: 22).opacity(0.4)
            column("Week", value: weekText)
            Divider().frame(height: 22).opacity(0.4)
            column("Month", value: monthText)
        }
    }

    private func column(_ label: String, value: String) -> some View {
        VStack(spacing: 1) {
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

    /// Local copy of Medium's `compactTokens` helper — kept private here
    /// to avoid cross-file coupling between two unrelated popover
    /// layouts. 14_300_000 → "14.3M", 312_000_000 → "312M".
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
