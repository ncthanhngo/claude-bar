import SwiftUI

// One home for every configuration screen — General, MCP, Briefing,
// Privacy, Diagnostics, About — picked from a tab strip across the top.
// Each detail pane is the existing tab view (GeneralTab, MCPTab, …) unmodified.
struct SettingsTab: View {
    @State private var selected: SettingsSubTab = .general

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().opacity(0.5)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(SettingsSubTab.allCases) { sub in
                SettingsTopTabButton(sub: sub, isSelected: sub == selected) {
                    selected = sub
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.025))
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

private struct SettingsTopTabButton: View {
    let sub: SettingsSubTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: sub.systemImage)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Text(sub.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .primary : (isHovering ? .primary.opacity(0.85) : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.15)
                          : Color.primary.opacity(isHovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(sub.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
