import SwiftUI

// Settings UI hosted inside a dedicated, center-screen NSWindow (see
// SettingsWindowController). Layout is sidebar-on-left + detail-on-right
// — the same Mail/Notes/Apple-Settings pattern users already expect on
// macOS. The earlier top-tab strip was constrained by popover width;
// inside its own window we get enough horizontal room for a real
// sidebar that groups items semantically (General app prefs vs
// system-level: Privacy / Diagnostics / About).
struct SettingsTab: View {
    @State private var selected: SettingsSubTab = .general
    @EnvironmentObject private var updateController: UpdateController

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(Color.primary.opacity(0.04))
            Divider().opacity(0.4)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Mount the Sparkle update overlay inside the Settings window too —
        // not just on the popover. The driver is the same instance shared
        // through the environment, so clicking "Check for updates…" in
        // About renders its progress / release-notes UI right here on
        // Settings instead of on the (possibly hidden) menu-bar popover.
        .overlay(UpdateOverlayView(driver: updateController.driver))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarGroup(title: "General", items: SettingsSubTab.appGroup)
            sidebarGroup(title: "System", items: SettingsSubTab.systemGroup)
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private func sidebarGroup(title: String, items: [SettingsSubTab]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            ForEach(items) { sub in
                SettingsSidebarItem(sub: sub, isSelected: sub == selected) {
                    selected = sub
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selected {
        case .general:     GeneralTab()
        case .mcp:         MCPTab()
        case .briefing:    BriefingTab()
        case .privacy:     PrivacyTab()
        case .diagnostics: DiagnosticsTab()
        case .about:       AboutTab()
        }
    }
}

enum SettingsSubTab: String, CaseIterable, Identifiable {
    case general, mcp, briefing, privacy, diagnostics, about

    var id: String { rawValue }

    /// User-facing app preferences — driving behavior of the menu-bar UI.
    static let appGroup: [SettingsSubTab] = [.general, .mcp, .briefing]
    /// System-level inspection / metadata — read-mostly screens.
    static let systemGroup: [SettingsSubTab] = [.privacy, .diagnostics, .about]

    var label: String {
        switch self {
        case .general:     return "General"
        case .mcp:         return "MCP"
        case .briefing:    return "Briefing"
        case .privacy:     return "Privacy"
        case .diagnostics: return "Diagnostics"
        case .about:       return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:     return "gearshape"
        case .mcp:         return "puzzlepiece.extension"
        case .briefing:    return "sun.haze"
        case .privacy:     return "hand.raised"
        case .diagnostics: return "stethoscope"
        case .about:       return "info.circle"
        }
    }
}

private struct SettingsSidebarItem: View {
    let sub: SettingsSubTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconBackground)
                        .frame(width: 22, height: 22)
                    Image(systemName: sub.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(iconForeground)
                }
                Text(sub.label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .animation(.easeInOut(duration: 0.10), value: isSelected)
        .animation(.easeInOut(duration: 0.10), value: isHovering)
        .accessibilityLabel(sub.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                Color.accentColor
            } else if isHovering {
                Color.primary.opacity(0.06)
            } else {
                Color.clear
            }
        }
    }

    private var iconBackground: Color {
        isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)
    }

    private var iconForeground: Color {
        isSelected ? .white : .secondary
    }
}
