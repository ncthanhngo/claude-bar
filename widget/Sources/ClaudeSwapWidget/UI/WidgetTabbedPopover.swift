import SwiftUI

// Tabs shown along the top of the menu-bar popover. Order is intentional:
// "Claude" sits at the middle (position 4 of 7) — it hosts the live widget
// content (account list, auto-swap, status). All other tabs are settings or
// info screens lifted out of the old standalone Settings window.
enum WidgetTab: String, CaseIterable, Identifiable {
    case accounts, general, mcp, claude, daily, diagnostics, privacy, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accounts:    return "Accounts"
        case .general:     return "General"
        case .mcp:         return "MCP"
        case .claude:      return "Claude"
        case .daily:       return "Daily"
        case .diagnostics: return "Diagnostics"
        case .privacy:     return "Privacy"
        case .about:       return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts:    return "person.2"
        case .general:     return "gearshape"
        case .mcp:         return "puzzlepiece.extension"
        case .claude:      return "sparkles"
        case .daily:       return "sun.haze"
        case .diagnostics: return "stethoscope"
        case .privacy:     return "hand.raised"
        case .about:       return "info.circle"
        }
    }
}

// Top-level container for the menu-bar popover. Header (status + force-refresh
// + health-check) sits at the top, a horizontal tab bar sits below it (joined
// segmented look — icon stacked over label, the selected segment gets the
// accent fill), and the selected tab's content fills the rest. A persistent
// footer (Briefing / Theme / Quit) sits at the bottom so global actions stay
// reachable from every tab.
struct WidgetTabbedPopover: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var updateController: UpdateController
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedTab: WidgetTab = .claude

    var body: some View {
        VStack(spacing: 0) {
            MenuHeaderBar()
            Divider().opacity(0.5)
            tabBar
            Divider().opacity(0.5)
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider().opacity(0.5)
            FooterActions()
                .padding(.bottom, 6)
        }
        .frame(width: 620, height: 860)
        .background(popoverBackground)
        .background(WindowAppearanceSetter(theme: settings.widgetTheme))
        .background(PopoverWindowCapture())
        // Sparkle update flow renders here, on top of the popover content,
        // so the popover never loses key status during the check/download/
        // install cycle. See InPopoverUpdateDriver for the rationale.
        .overlay(UpdateOverlayView(driver: updateController.driver))
        .overlay(alignment: .bottom) {
            // Phase 2 — inline confirm-gate chip floats above the active tab.
            // Destructive prompts use the sheet modifier on the popover root
            // (in ClaudeSwapWidgetApp) and don't render here.
            ConfirmGateOverlay()
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left:  selectedTab = neighbour(of: selectedTab, offset: -1)
            case .right: selectedTab = neighbour(of: selectedTab, offset: +1)
            default: break
            }
        }
    }

    @ViewBuilder
    private var popoverBackground: some View {
        if settings.widgetTheme.useVibrancy {
            // Apple-style: NSVisualEffectView with `.menu` material — same
            // background AppKit menu-bar popovers have always used. Going
            // through AppKit avoids the SwiftUI material layout quirks where
            // children collapse to zero height after async data loads inside
            // `MenuBarExtra`.
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
        } else {
            settings.widgetTheme.background
        }
    }

    private func neighbour(of current: WidgetTab, offset: Int) -> WidgetTab {
        let all = WidgetTab.allCases
        guard let idx = all.firstIndex(of: current) else { return current }
        let next = (idx + offset + all.count) % all.count
        return all[next]
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(WidgetTab.allCases) { tab in
                WidgetTabBarButton(tab: tab, isSelected: tab == selectedTab) {
                    selectedTab = tab
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .accounts:    AccountsTab()
        case .general:     GeneralTab()
        case .mcp:         MCPTab()
        case .claude:      ClaudeTabContent()
        case .daily:       BriefingTab()
        case .diagnostics: DiagnosticsTab()
        case .privacy:     PrivacyTab()
        case .about:       AboutTab()
        }
    }
}

// One segment of the joined tab bar. Vertical layout (icon stacked over
// label) to match the design reference; the selected segment is filled with
// the accent tint. Adjacent segments touch — `spacing: 0` in the parent HStack
// — so the bar reads as a single continuous strip.
private struct WidgetTabBarButton: View {
    let tab: WidgetTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                Text(tab.label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .cornerRadius(1)
                    .padding(.horizontal, 6)
            }
            .foregroundColor(isSelected ? .primary : (isHovering ? .primary.opacity(0.85) : .secondary))
            .padding(.horizontal, 4)
            .padding(.top, 7)
            .padding(.bottom, 0)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && !isSelected ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// Claude tab — the live widget. Same content the popover used to show before
// the tab bar refactor (account list + auto-swap toggle + status). The global
// footer (Briefing / Theme / Quit) lives on the popover root, not inside
// this tab.
struct ClaudeTabContent: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cloudSync: CloudSyncCoordinator
    @ObservedObject private var settings = AppSettings.shared

    // Mirrors AppSettings.lastAutoSync* via the same UserDefaults keys so the
    // Accounts-header sync chip re-renders the moment a background cycle
    // updates these timestamps — no need to wait for an AppStore publish.
    @AppStorage("lastAutoSyncAt") private var lastAutoSyncAt: Double = 0
    @AppStorage("lastAutoSyncSuccessAt") private var lastAutoSyncSuccessAt: Double = 0
    @AppStorage("lastAutoSyncError") private var lastAutoSyncError: String = ""
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = false

    var body: some View {
        // GeometryReader → ScrollView → VStack with `minHeight: geo.height`
        // makes the content stretch to fill the tab area when it's shorter
        // than the popover (1–2 accounts case), so TokenStatsSection's chart
        // expands to absorb the slack instead of leaving a blank strip below
        // the summary cards. Content longer than the tab area (6+ accounts
        // before the inner list scroll kicks in) still scrolls normally —
        // `minHeight` only sets a floor.
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    accountsHeader
                    AccountListSection()
                    sectionTitle(title: "Auto-swap").padding(.top, 6)
                    AutoSwapSection()
                    sectionTitle(title: "Token usage").padding(.top, 6)
                    TokenStatsSection()
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.vertical, 6)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
    }

    /// Accounts section header with the auto-sync chip sitting right next
    /// to the title (not jammed against the count on the right edge) so the
    /// two trailing slots — sync status and account count — stay visually
    /// separate. Baseline-aligned so the smaller chip glyphs sit on the
    /// same line as the bold title text.
    private var accountsHeader: some View {
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

    /// Compact iCloud-sync indicator: glance-only, three visible states.
    ///   - green check + relative time = last cycle ok within memory
    ///   - amber triangle = last attempt failed but a recent success exists
    ///   - red triangle = no success in 12h+
    /// Hidden entirely when iCloud sync isn't enabled or no cycle has run
    /// yet, so the header stays clean for users who don't use sync.
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

    /// Compact "Xs / Xm / Xh / Xd" used inline in the header chip so it
    /// fits next to the account count without wrapping. Returns "now"
    /// under a minute.
    private func relativeShort(seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        if s < 60         { return "now" }
        if s < 60 * 60    { return "\(s / 60)m" }
        if s < 24 * 3600  { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    // Replaces the old ALL-CAPS gray SectionHeaderView with a softer bold
    // inline title — same vertical footprint (~22pt) so the existing layout
    // still fits the popover frame.
    @ViewBuilder
    private func sectionTitle(title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}
