import SwiftUI

// Tabs shown along the top of the menu-bar popover. Four primary surfaces:
//   Dashboard — glanceable active account + Today/Week/Month KPIs.
//   Accounts  — full account list + auto-swap controls + add/verify.
//   Stats     — read-only token-usage analytics (chart + KPI strip).
//   Settings  — sidebar hosting General/MCP/Briefing/Privacy/Diagnostics/About.
// Previously eight tabs mixed data and settings (Accounts/General/MCP/Claude/
// Daily/Diagnostics/Privacy/About); collapsing them into 4 puts "what's going
// on" up top and stows the configuration screens behind a single Settings
// surface.
enum WidgetTab: String, CaseIterable, Identifiable {
    case dashboard, accounts, stats, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .accounts:  return "Accounts"
        case .stats:     return "Stats"
        case .settings:  return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "rectangle.grid.2x2"
        case .accounts:  return "person.2"
        case .stats:     return "chart.line.uptrend.xyaxis"
        case .settings:  return "gearshape"
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
    @State private var selectedTab: WidgetTab = .dashboard

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
        case .dashboard: DashboardTab()
        case .accounts:  AccountsTab()
        case .stats:     StatsTab()
        case .settings:  SettingsTab()
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
