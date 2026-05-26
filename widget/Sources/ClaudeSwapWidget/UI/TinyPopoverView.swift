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
    // Each row is avatar 22 + 8pt vertical padding × 2 + chip height ≈ 46.
    private static let rowHeight: CGFloat = 46
    // Header (~32) + divider + list padding + Auto-swap bar (toggle row
    // ~22 + slider 30 + legend 16 + paddings ~16 = ~84) = ~140.
    private static let shellHeight: CGFloat = 140

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MenuHeaderBar()
                    .padding(.top, 4)
                Divider().opacity(0.5)
                ScrollView(.vertical, showsIndicators: false) {
                    accountList
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.4)
                TinyAutoSwapBar()
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
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

    /// Caps at 6 visible rows. Beyond that the list scrolls internally so
    /// the popover frame never grows unbounded. Empty state has its own
    /// height so the popover isn't a tall blank rectangle when the user
    /// has no accounts yet.
    private var popoverHeight: CGFloat {
        let count = store.snapshot?.accounts.count ?? 0
        // Hug content tightly — every popover layout previously left a
        // visible empty strip below the last row. The `+ 4` covers list
        // top/bottom padding (4 each); no extra slack.
        switch count {
        case 0:     return 160
        case 1...6: return Self.shellHeight + Self.rowHeight * CGFloat(count) + 4
        default:    return Self.shellHeight + Self.rowHeight * 6 + 4
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
    private var accountList: some View {
        if let snap = store.snapshot, !snap.accounts.isEmpty {
            let sorted = snap.accounts.sorted { $0.isActive && !$1.isActive }
            VStack(spacing: 2) {
                ForEach(sorted) { acc in
                    TinyAccountRow(view: acc)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        } else {
            EmptyAccountsView().padding(.top, 16)
        }
    }
}

/// Stripped-down account row. The two `UsageChip`s are the only quota
/// surface — they replace the full usage bars from Standard/Medium with
/// a tiny "5h X%" / "7d Y%" pill each.
private struct TinyAccountRow: View {
    let view: AccountViewDTO
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
        // The value reads in `UsagePalette.percentText` (blue) so the
        // number itself is high-contrast and consistent with Standard /
        // Full. The chip's background and border still pick up the
        // traffic-light palette so the quota tier (safe / warn / critical)
        // is encoded in the surrounding tint without the digit colour
        // shifting under the eye.
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(valueText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(valueColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
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
