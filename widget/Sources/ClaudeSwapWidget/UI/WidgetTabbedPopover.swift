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

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MenuHeaderBar()
                    .padding(.top, 6)
                Divider().opacity(0.5)
                ScrollView(.vertical, showsIndicators: false) {
                    mainBody
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 440, height: popoverHeight)
        .animation(.easeInOut(duration: 0.18), value: popoverHeight)
        .background(popoverBackground)
        .background(WindowAppearanceSetter(theme: settings.widgetTheme))
        .background(PopoverWindowCapture())
        .overlay(UpdateOverlayView(driver: updateController.driver))
        .overlay(alignment: .bottom) { ConfirmGateOverlay() }
        .overlay { SwapErrorOverlay() }
        .focusable()
        .focusEffectDisabled()
    }

    /// Popover height adapts to the visible account count:
    ///   • 0 / no snapshot → empty-state size (no full account list)
    ///   • 1 account       → compact
    ///   • 2 accounts      → mid
    ///   • 3+ accounts     → full size; the account list itself caps at
    ///                       3 visible rows and scrolls internally past
    ///                       that, so the popover frame never grows past
    ///                       the 3-row layout.
    private var popoverHeight: CGFloat {
        let count = store.snapshot?.accounts.count ?? 0
        // Per-account row height ≈ 95pt (avatar + email + 5h/7d bars). The
        // "shell" (header + accounts header + auto-swap + token usage +
        // paddings) takes the remainder.
        let shellHeight: CGFloat = 475
        let rowHeight: CGFloat = 95
        switch count {
        case 0:      return 520            // empty-state card centred in the body
        case 1:      return shellHeight + rowHeight        // 570
        case 2:      return shellHeight + rowHeight * 2    // 665
        default:     return shellHeight + rowHeight * 3    // 760 — cap at 3 rows; rest scroll
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
        // Plain VStack inside the ScrollView — no `maxHeight: .infinity`
        // on children (would force them to fill the scroll content and
        // defeat scrolling). Bottom padding gives the last KPI card
        // breathing room when the scroll is at its bottom limit.
        VStack(alignment: .leading, spacing: 4) {
            accountsHeader
            AccountListSection()
            sectionTitle("Auto-swap").padding(.top, 6)
            AutoSwapSection()
            sectionTitle("Token usage").padding(.top, 6)
            TokenStatsSection()
        }
        .padding(.top, 6)
        .padding(.bottom, 12)
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
