import SwiftUI

// Settings UI hosted inside a dedicated, center-screen NSWindow (see
// SettingsWindowController). Layout = sidebar (220pt) + detail. Sidebar is
// split into four semantic groups so each item does exactly one job:
//
//   APP          — basic cosmetics + the canonical Accounts surface
//   FEATURES     — opt-in workflows (IDE reload, Briefing, Local MCP)
//   DATA & SYNC  — anything that backs up, restores, or inspects state
//   SYSTEM       — read-mostly screens (privacy, updates, about)
//
// The earlier "General / System" pair conflated cosmetic prefs with feature
// surfaces (MCP, Briefing) and dumped Diagnostics + iCloud Sync under the
// Update tab. Four groups is short enough to scan without scrolling and
// long enough to separate concerns the user reasons about differently.
struct SettingsTab: View {
    // Persisted between window opens. Re-opening Settings lands on the
    // tab the user last had focused — small thing, but it means jumping
    // back to "the screen I was just configuring" is free.
    @AppStorage("settingsLastTab") private var lastTabRaw: String = SettingsSubTab.general.rawValue
    @State private var selected: SettingsSubTab = .general
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    @EnvironmentObject private var updateController: UpdateController

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(Color.primary.opacity(0.04))
            Divider().opacity(0.4)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Force a fresh detail subtree per tab. Without an `.id`
                // tied to `selected`, SwiftUI may reuse the previous
                // tab's NSScrollView for the new tab's content — which
                // landed users mid-page (e.g. on MCP's chat-tool-mode
                // card) before the page settled back to the top.
                .id(selected)
                // Without this, the implicit `.animation(...)` on the
                // sidebar item's `isSelected` propagates down into the
                // detail rebuild and SwiftUI cross-fades the old tab
                // out / new tab in — during the cross-fade the user sees
                // both views layered, perceived as a flash.
                .transaction { $0.animation = nil }
        }
        // Mount the Sparkle update overlay inside the Settings window too —
        // not just on the popover. The driver is the same instance shared
        // through the environment, so clicking "Check for updates…" in
        // Update renders its progress / release-notes UI right here on
        // Settings instead of on the (possibly hidden) menu-bar popover.
        .overlay(UpdateOverlayView(driver: updateController.driver))
        // ⌘F focuses the sidebar search field. Hidden Button placed in
        // overlay so the shortcut works window-wide without stealing a
        // visible toolbar slot.
        .overlay(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .onAppear {
            if let restored = SettingsSubTab(rawValue: lastTabRaw) {
                selected = restored
            }
        }
        .onChange(of: selected) { _, new in
            lastTabRaw = new.rawValue
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let groups = filteredGroups()
                    if groups.isEmpty {
                        emptySearchState
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.offset) { idx, group in
                            sidebarGroup(title: group.title, items: group.items)
                                .padding(.top, idx == 0 ? 0 : 14)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextField("Search (⌘F)", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit {
                    // Enter selects the first match — Spotlight pattern.
                    if let first = filteredGroups().first?.items.first {
                        selected = first
                        searchText = ""
                        searchFocused = false
                    }
                }
                .onChange(of: searchText) { _, q in
                    // Auto-jump to first match while typing so the detail
                    // pane previews live, without losing the user's
                    // typing focus.
                    if !q.isEmpty, let first = filteredGroups().first?.items.first {
                        if selected != first { selected = first }
                    }
                }
                .onExitCommand {
                    // Esc clears the query (or unfocuses if already empty).
                    if !searchText.isEmpty { searchText = "" }
                    else { searchFocused = false }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(searchFocused ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.accentColor.opacity(searchFocused ? 0.5 : 0), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.12), value: searchFocused)
    }

    private var emptySearchState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
            Text("No matches")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    /// Returns the four sidebar groups with items filtered by `searchText`.
    /// Empty groups are dropped so the user doesn't stare at an orphan
    /// header. Case-insensitive substring match on the user-visible label.
    private func filteredGroups() -> [(title: String, items: [SettingsSubTab])] {
        let raw: [(String, [SettingsSubTab])] = [
            ("App",         SettingsSubTab.appGroup),
            ("Features",    SettingsSubTab.featuresGroup),
            ("Data & Sync", SettingsSubTab.dataGroup),
            ("System",      SettingsSubTab.systemGroup),
        ]
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return raw.map { (title: $0.0, items: $0.1) } }
        return raw.compactMap { (title, items) in
            let filtered = items.filter { $0.label.localizedCaseInsensitiveContains(q) }
            return filtered.isEmpty ? nil : (title: title, items: filtered)
        }
    }

    private func sidebarGroup(title: String, items: [SettingsSubTab]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundColor(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
            ForEach(items) { sub in
                SettingsSidebarItem(sub: sub, isSelected: sub == selected) {
                    // Wrap in non-animated transaction so the detail
                    // pane's view rebuild does not cross-fade. The
                    // implicit `.animation(...)` on the row's own
                    // hover/selected state still applies because that
                    // modifier runs after this transaction completes.
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { selected = sub }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selected {
        case .general:     GeneralTab()
        case .accounts:    AccountsTab()
        case .ide:         IDEIntegrationTab()
        case .briefing:    BriefingTab()
        case .mcp:         MCPTab()
        case .iCloudSync:  DiagnosticsTab(mode: .iCloud)
        case .diagnostics: DiagnosticsTab(mode: .diagnostics)
        case .privacy:     PrivacyTab()
        case .update:      UpdateTab()
        case .about:       AboutTab()
        }
    }
}

enum SettingsSubTab: String, CaseIterable, Identifiable {
    case general, accounts, ide, briefing, mcp, iCloudSync, diagnostics, privacy, update, about

    var id: String { rawValue }

    /// Cosmetic basics + canonical Accounts surface.
    static let appGroup: [SettingsSubTab] = [.general, .accounts]
    /// Opt-in workflows that wire Claude Bar into the rest of the user's
    /// toolchain — each has enough surface area to deserve its own tab.
    static let featuresGroup: [SettingsSubTab] = [.ide, .briefing, .mcp]
    /// Anything that backs up, restores, or inspects state.
    static let dataGroup: [SettingsSubTab] = [.iCloudSync, .diagnostics]
    /// Read-mostly screens.
    static let systemGroup: [SettingsSubTab] = [.privacy, .update, .about]

    var label: String {
        switch self {
        case .general:     return "General"
        case .accounts:    return "Accounts"
        case .ide:         return "IDE Integration"
        case .briefing:    return "Briefing"
        case .mcp:         return "Local MCP"
        case .iCloudSync:  return "iCloud Sync"
        case .diagnostics: return "Diagnostics"
        case .privacy:     return "Privacy"
        case .update:      return "Updates"
        case .about:       return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:     return "gearshape.fill"
        case .accounts:    return "person.2.fill"
        case .ide:         return "macwindow.on.rectangle"
        case .briefing:    return "sun.haze.fill"
        case .mcp:         return "puzzlepiece.extension.fill"
        case .iCloudSync:  return "icloud.fill"
        case .diagnostics: return "stethoscope"
        case .privacy:     return "hand.raised.fill"
        case .update:      return "arrow.down.circle.fill"
        case .about:       return "info.circle.fill"
        }
    }

    /// Per-tab tint applied to the sidebar icon chip — the System
    /// Settings move that makes scanning a sidebar full of similarly
    /// shaped rows much faster than a wall of grey glyphs.
    var tint: Color {
        switch self {
        case .general:     return .gray
        case .accounts:    return .blue
        case .ide:         return .purple
        case .briefing:    return .orange
        case .mcp:         return .teal
        case .iCloudSync:  return .cyan
        case .diagnostics: return .red
        case .privacy:     return .pink
        case .update:      return .green
        case .about:       return .secondary
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .animation(.easeInOut(duration: 0.10), value: isSelected)
        .animation(.easeInOut(duration: 0.10), value: isHovering)
        .accessibilityLabel(sub.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Inset rounded pill — matches the look modern macOS apps (Settings,
    /// Notes, Reminders) use for their sidebar selection chrome. Selected
    /// row gets a solid accent fill; hover gets a translucent neutral so
    /// the user feels the row light up before they click.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(fillColor)
    }

    private var fillColor: Color {
        if isSelected { return Color.accentColor }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }

    /// Unselected: the tab's own tint at low opacity so the row reads
    /// like a colored chip. Selected: a soft white pane over the accent
    /// fill so the icon stays legible without fighting the row colour.
    private var iconBackground: Color {
        isSelected ? Color.white.opacity(0.22) : sub.tint.opacity(0.18)
    }

    private var iconForeground: Color {
        isSelected ? .white : sub.tint
    }
}
