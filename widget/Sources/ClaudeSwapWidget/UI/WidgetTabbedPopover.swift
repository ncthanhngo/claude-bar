import SwiftUI

// Menu-bar popover root. One scrollable surface, no top tabs, no footer.
// All global actions (Add account, Verify all, Force refresh, Health
// check, Theme, Quit, Settings) live as icons in the header bar — Settings
// pinned to the top-right corner. The body is just status header → account
// list → auto-swap → token usage.
//
// Name kept as `WidgetTabbedPopover` only for git history; the structure has
// nothing tabbed about it now.
struct WidgetTabbedPopover: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cloudSync: CloudSyncCoordinator
    @EnvironmentObject private var updateController: UpdateController
    @ObservedObject private var settings = AppSettings.shared

    @AppStorage("lastAutoSyncSuccessAt") private var lastAutoSyncSuccessAt: Double = 0
    @AppStorage("lastAutoSyncError") private var lastAutoSyncError: String = ""
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = false

    /// Maximum account rows shown at full height before the in-list
    /// scroll engages. Matches Standard's behaviour so the layouts feel
    /// related: ≤ 3 accounts means no scroll bar anywhere, 4+ means the
    /// account list scrolls internally while the auto-swap + token
    /// dashboard underneath stays pinned.
    private static let accountsRowsBeforeScroll = 3
    private static let popoverWidth: CGFloat = 400
    /// Re-measured against the rendered shell: header 36 + divider 1 +
    /// accountsHeader 22 + divider 1 + auto-swap title 22 + auto-swap
    /// section 86 + token-usage title 22 + token stats minimum 196
    /// + outer paddings ~16 = 402pt. Was 475 — that overshoot is what
    /// pushed the popover taller than it needed to be even with one
    /// account.
    private static let shellHeight: CGFloat = 402
    /// One AccountRowView (Full's verbose row with avatar, email, full
    /// 5h/7d bars, reset countdowns). Measured at ~100pt in practice;
    /// the previous 95pt undersized the row by enough that 3 accounts
    /// already overflowed.
    private static let rowHeight: CGFloat = 100

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MenuHeaderBar()
                    .padding(.top, 6)
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
        .overlay(
            // Hairline border so the popover edge stays crisp against
            // bright wallpapers — macOS' default popover chrome is
            // subtle and disappears on light desktops. 8pt corner
            // radius matches the system popover shape.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .overlay(UpdateOverlayView(driver: updateController.driver))
        .overlay(alignment: .bottom) { ConfirmGateOverlay() }
        .overlay { SwapErrorOverlay() }
        .focusable()
        .focusEffectDisabled()
    }

    private var popoverHeight: CGFloat {
        Self.shellHeight + visibleAccountsHeight
    }

    /// Height the account list actually consumes — capped at three
    /// rows. Beyond that, the inner ScrollView scrolls; the popover
    /// frame stops growing. Same shape Standard's popover uses.
    private var visibleAccountsHeight: CGFloat {
        let count = store.snapshot?.accounts.count ?? 0
        if count == 0 { return 0 }
        let visible = min(count, Self.accountsRowsBeforeScroll)
        return CGFloat(visible) * Self.rowHeight + CGFloat(max(0, visible - 1)) * 3 + 8
    }

    @ViewBuilder
    private var popoverBackground: some View {
        if settings.widgetTheme.useVibrancy {
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
        } else {
            settings.widgetTheme.background
        }
    }

    /// Account list, bounded so it never pushes the bottom sections
    /// off-screen. Up to three rows visible at full height; beyond
    /// that the inner ScrollView engages while the popover frame
    /// stops growing.
    @ViewBuilder
    private var accountsSection: some View {
        if let snap = store.snapshot, !snap.accounts.isEmpty {
            let sorted = snap.accounts.sorted { $0.isActive && !$1.isActive }
            let hasOverflow = sorted.count > Self.accountsRowsBeforeScroll
            ScrollView(.vertical, showsIndicators: hasOverflow) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(sorted) { acc in
                        AccountRowView(view: acc, onRename: { promptRename(for: acc) })
                    }
                }
                .padding(.horizontal, 8)
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

    /// Always-visible footer — auto-swap + token-usage sections. Lives
    /// outside any ScrollView so the user can drag the threshold
    /// slider, read totals, or interact with chart controls even when
    /// the account list above is scrolling.
    private var bottomFixedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Auto-swap").padding(.top, 6)
            AutoSwapSection()
            sectionTitle("Token usage").padding(.top, 6)
            TokenStatsSection()
        }
        .padding(.bottom, 8)
    }

    private func promptRename(for acc: AccountViewDTO) {
        AccountRenamePrompt.run(for: acc) { newName in
            Task { await store.rename(acc.account.number, to: newName) }
        }
    }

    private var accountsHeader: some View {
        // Verify all moved to the global header (icon-only). This row stays
        // just for the "Accounts" label + iCloud sync chip + account count.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Accounts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            syncChip
            Spacer()
            if let count = store.snapshot.map({ "\($0.accounts.count)" }) {
                Text(count)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }

    // Compact iCloud-sync indicator: green/amber/red. Hidden when sync isn't
    // enabled or no cycle has run yet, so the header stays clean for users
    // who don't use sync.
    @ViewBuilder
    private var syncChip: some View {
        let cloudEnabled = iCloudSyncEnabled && cloudSync.status?.exists == true
        let hasSuccess = lastAutoSyncSuccessAt > 0
        let attemptFailed = !lastAutoSyncError.isEmpty
        let now = Date().timeIntervalSince1970
        let successAge = hasSuccess ? now - lastAutoSyncSuccessAt : .infinity
        let isBroken = attemptFailed && successAge > 12 * 3600

        if cloudEnabled && (hasSuccess || attemptFailed) {
            if isBroken {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text("sync failing")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                .help(lastAutoSyncError.isEmpty
                      ? "Auto-sync hasn't succeeded in 12h+ — open Diagnostics to investigate."
                      : "Auto-sync failing: \(lastAutoSyncError)")
            } else if attemptFailed {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(relativeShort(seconds: successAge))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
                .help("Last sync attempt failed. Previous success \(relativeShort(seconds: successAge)) ago.\n\(lastAutoSyncError)")
            } else if hasSuccess {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text(relativeShort(seconds: successAge))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .help("iCloud auto-sync ok — last cycle \(relativeShort(seconds: successAge)) ago.")
            }
        }
    }

    private func relativeShort(seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        if s < 60         { return "now" }
        if s < 60 * 60    { return "\(s / 60)m" }
        if s < 24 * 3600  { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
