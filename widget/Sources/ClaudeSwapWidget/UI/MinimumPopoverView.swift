import SwiftUI

/// Minimum popover layout. Header bar + account list. No auto-swap slider,
/// no token-usage chart, no per-account usage bars. The list itself uses a
/// stripped-down row that shows just initial + display name + ACTIVE dot,
/// so the popover collapses to roughly half the height of the standard one
/// and renders instantly.
///
/// Picked via Settings → General → Popover layout = Minimum. Live-switches
/// without restart because the root scene branches on `settings.popoverLayout`.
struct MinimumPopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var updateController: UpdateController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MenuHeaderBar()
                    .padding(.top, 6)
                Divider().opacity(0.5)
                ScrollView(.vertical, showsIndicators: false) {
                    accountList
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 340, height: popoverHeight)
        .animation(.easeInOut(duration: 0.18), value: popoverHeight)
        .background(popoverBackground)
        .background(WindowAppearanceSetter(theme: settings.widgetTheme))
        .background(PopoverWindowCapture())
        .overlay(UpdateOverlayView(driver: updateController.driver))
        .overlay { SwapErrorOverlay() }
        .focusable()
        .focusEffectDisabled()
    }

    /// Tiny shell + ~46pt per row. Caps at 6 rows, anything past that
    /// scrolls inside the list. The empty state gets its own small height
    /// instead of leaving a tall blank popover.
    private var popoverHeight: CGFloat {
        let count = store.snapshot?.accounts.count ?? 0
        let shell: CGFloat = 70
        let row: CGFloat = 46
        switch count {
        case 0:     return 220
        case 1...6: return shell + row * CGFloat(count) + 12
        default:    return shell + row * 6 + 12
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
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sorted) { acc in
                    MinimumAccountRow(view: acc)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        } else {
            EmptyAccountsView()
                .padding(.top, 20)
        }
    }
}

/// Stripped-down account row for the minimum layout. Click-to-swap on the
/// whole row (no separate Switch button), inline ACTIVE dot, no usage bars,
/// no organisation chip, no more-button overflow.
private struct MinimumAccountRow: View {
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
                trailing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
            ProgressView().controlSize(.small)
        } else if view.isActive {
            Circle()
                .fill(settings.widgetTheme.activeAccent)
                .frame(width: 9, height: 9)
        }
    }

    private var rowBackground: Color {
        if view.isActive { return settings.widgetTheme.activeAccent.opacity(0.12) }
        if isHovering    { return Color.primary.opacity(0.06) }
        return .clear
    }
}
