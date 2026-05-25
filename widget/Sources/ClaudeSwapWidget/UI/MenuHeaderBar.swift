import SwiftUI

// Outcome of a force-refresh attempt. Carries its own icon/title/cooldown
// decision so the popover view doesn't have to parse message strings.
//
// Kept at module scope (not private) so DiagnosticsTab can reuse it — the
// force-refresh action moved out of the header into Diagnostics, but the
// outcome model is shared.
enum ForceRefreshOutcome {
    case success
    case rateLimited(detail: String)
    case error(detail: String)

    var triggerCooldown: Bool {
        if case .success = self { return true }
        return false
    }

    var iconName: String {
        switch self {
        case .success:     return "checkmark.seal.fill"
        case .rateLimited: return "clock.badge.exclamationmark"
        case .error:       return "exclamationmark.triangle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .success:                return .green
        case .rateLimited, .error:    return .orange
        }
    }

    var title: String {
        switch self {
        case .success:     return "Credentials refreshed"
        case .rateLimited: return "Rate limited"
        case .error:       return "Refresh finished with errors"
        }
    }

    var message: String {
        switch self {
        case .success:
            return "Credentials refreshed for all inactive accounts."
        case .rateLimited(let detail):
            return "Rate limited by Anthropic — try again later. \(detail)"
        case .error(let detail):
            return "Some accounts failed to refresh: \(detail)"
        }
    }
}

/// Slim header: status (left) + Theme · Quit · Settings (right, evenly
/// spaced). All other actions migrated to Settings:
///   • Add account     → Settings → General
///   • Verify all      → Settings → Diagnostics
///   • Force refresh   → Settings → Diagnostics
///   • Health check    → folded into Verify (same backend call)
///   • Briefing pill   → removed entirely; use ⌥X hotkey
struct MenuHeaderBar: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            // Left side — status dot + timestamp.
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(store.lastError == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Right side — 3 chrome buttons evenly spaced. Settings anchors
            // the top-right corner per the design spec.
            HStack(spacing: 18) {
                themeButton
                quitButton
                settingsButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Right-side buttons

    private var themeButton: some View {
        Button(action: { settings.widgetTheme = settings.widgetTheme.next }) {
            themeIcon
        }
        .buttonStyle(.borderless)
        .help("Theme: \(settings.widgetTheme.rawValue) — click to cycle")
        .pointingHandCursor()
        .accessibilityLabel("Cycle theme")
    }

    @ViewBuilder private var themeIcon: some View {
        switch settings.widgetTheme {
        case .light:
            Image(systemName: "sun.max").font(.system(size: 13)).foregroundColor(.secondary)
        case .dark:
            Image(systemName: "moon").font(.system(size: 13)).foregroundColor(.secondary)
        case .apple:
            Image(systemName: "apple.logo").font(.system(size: 13)).foregroundColor(.secondary)
        case .rainbow:
            Circle()
                .fill(AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                    center: .center
                ))
                .frame(width: 13, height: 13)
        }
    }

    private var quitButton: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Image(systemName: "power")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Quit Claude Bar (⌘Q)")
        .pointingHandCursor()
        .accessibilityLabel("Quit")
    }

    private var settingsButton: some View {
        Button(action: { SettingsWindowController.shared.show() }) {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Open Settings")
        .pointingHandCursor()
        .accessibilityLabel("Settings")
    }

    // MARK: - Status

    private var statusDotColor: Color {
        if store.lastError != nil { return .red }
        if store.isRefreshing    { return .orange }
        return .green
    }

    private var statusText: String {
        if let err = store.lastError { return err }
        guard let when = store.lastRefreshAt else { return "Loading…" }
        let secs = max(0, Int(Date().timeIntervalSince(when)))
        if secs < 5  { return "Updated just now" }
        if secs < 60 { return "Updated \(secs)s ago" }
        return "Updated \(secs / 60)m ago"
    }
}
