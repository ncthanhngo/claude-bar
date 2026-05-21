import Foundation
import SwiftUI

/// User-tweakable settings persisted via UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("autoSwapEnabled") var autoSwapEnabled: Bool = false
    @AppStorage("thresholdPct") var thresholdPct: Int = 90
    /// Refresh interval used when active 5h utilisation is below
    /// `adaptiveHighThresholdPct`. Default 180s (3 min).
    @AppStorage("refreshIntervalSec") var refreshIntervalSec: Int = 180

    /// Refresh interval used when active 5h utilisation is at or above
    /// `adaptiveHighThresholdPct`. Default 120s (2 min). Picked so the
    /// widget reacts faster as we approach the auto-swap threshold.
    @AppStorage("refreshIntervalHighSec") var refreshIntervalHighSec: Int = 120

    /// Cutoff (%) where we switch from "low" to "high" refresh frequency.
    @AppStorage("adaptiveHighThresholdPct") var adaptiveHighThresholdPct: Int = 80
    @AppStorage("sessionPollIntervalSec") var sessionPollIntervalSec: Int = 5
    @AppStorage("menuBarStyle") var menuBarStyle: MenuBarStyle = .compact
    @AppStorage("aggressiveAutoKill") var aggressiveAutoKill: Bool = false

    /// When true, automatically reloads supported IDE windows after a swap.
    /// to every running IDE (VSCode, Cursor, Windsurf…) after a successful swap.
    /// Requires Accessibility permission the first time.
    @AppStorage("autoReloadIDEAfterSwap") var autoReloadIDEAfterSwap: Bool = false

    /// When true, sends SIGINT to every interactive `claude` CLI session after
    /// a swap. Useful with the `claude-watch` wrapper script which auto-restarts.
    @AppStorage("autoKillCLIAfterSwap") var autoKillCLIAfterSwap: Bool = false
    @AppStorage("widgetTheme") var widgetTheme: WidgetTheme = .light
    /// Timestamp of the last backup token refresh attempt (written before RPC).
    /// Used to throttle attempt frequency — prevents hammering Anthropic on
    /// repeated grant failures. Transient failures retry after a shorter window;
    /// see `backupTokenRefreshIfNeeded()` in AppStore for the full policy.
    @AppStorage("lastBackupTokenRefreshAt") var lastBackupTokenRefreshAt: Double = 0

    /// Timestamp of the last *successful* backup token refresh (written after RPC).
    /// Compared against `lastBackupTokenRefreshAt` to distinguish a transient
    /// failure (last attempt failed, retry sooner) from a persistent one (keep
    /// the full 6-hour throttle so broken grants don't cause refresh spam).
    @AppStorage("lastBackupTokenRefreshSuccessAt") var lastBackupTokenRefreshSuccessAt: Double = 0
    @AppStorage("menuBarIconColor") var menuBarIconColor: MenuBarIconColor = .system
}

enum WidgetTheme: String, CaseIterable, Identifiable {
    case light, dark, rainbow

    var id: String { rawValue }

    var isDark: Bool { self == .dark }

    var next: WidgetTheme {
        switch self {
        case .light:   return .dark
        case .dark:    return .rainbow
        case .rainbow: return .light
        }
    }

    // MARK: Colors

    var background: Color {
        switch self {
        case .light:   return .white
        case .dark:    return Color(white: 0.14)
        case .rainbow: return Color(red: 0.99, green: 0.95, blue: 1.0)
        }
    }

    var activeAccent: Color {
        switch self {
        case .light, .dark: return .green
        case .rainbow:      return Color(red: 0.75, green: 0.2, blue: 0.85)
        }
    }

    var activeChipBackground: Color {
        switch self {
        case .light, .dark: return .green
        case .rainbow:      return Color(red: 0.85, green: 0.15, blue: 0.65)
        }
    }

    var sectionHeaderColor: Color {
        switch self {
        case .light, .dark: return .secondary
        case .rainbow:      return Color(red: 0.6, green: 0.2, blue: 0.8)
        }
    }
}

enum MenuBarIconColor: String, CaseIterable, Identifiable {
    case system
    case white, gray
    case blue, teal, green, yellow, orange, red, pink, purple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        default:      return rawValue.capitalized
        }
    }

    /// nil = use system/template rendering (follows menu bar appearance)
    var color: Color? {
        switch self {
        case .system: return nil
        case .white:  return .white
        case .gray:   return .gray
        case .blue:   return .blue
        case .teal:   return Color(red: 0.18, green: 0.78, blue: 0.75)
        case .green:  return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red:    return .red
        case .pink:   return Color(red: 1.0, green: 0.45, blue: 0.70)
        case .purple: return .purple
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case iconOnly
    case compact
    case full

    var id: String { rawValue }
    var label: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .compact:  return "Compact (icon + %)"
        case .full:     return "Full (name + % + reset)"
        }
    }
}
