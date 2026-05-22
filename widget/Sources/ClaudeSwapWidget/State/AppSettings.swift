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
    /// VSCode-style string of the reload shortcut injected into VSCode-family
    /// editors and replayed by `IDEReloader`. Default `cmd+ctrl+r`.
    @AppStorage("reloadShortcut") var reloadShortcut: String = "cmd+ctrl+r"

    /// When true, the app keeps the reload shortcut synced into the
    /// keybindings.json of every detected VSCode-family editor.
    @AppStorage("injectReloadShortcut") var injectReloadShortcut: Bool = true

    @AppStorage("widgetTheme") var widgetTheme: WidgetTheme = .light

    /// Active body of the Daily window: "plan" (editorial briefing) or "chat"
    /// (OAuth-bound conversation thread). Persisted so the window opens in
    /// whichever mode the user last used.
    @AppStorage("dailyMode") var dailyMode: String = DailyMode.plan.rawValue

    // MARK: - Daily Briefing hotkeys (Carbon key codes + modifier bitmask)

    @AppStorage("briefingHotkeyOpenAppKeyCode")
    var briefingHotkeyOpenAppKeyCode: Int = 6   // kVK_ANSI_Z

    @AppStorage("briefingHotkeyOpenAppModifiers")
    var briefingHotkeyOpenAppModifiers: Int = 2048 // optionKey

    @AppStorage("briefingHotkeyOpenBriefingKeyCode")
    var briefingHotkeyOpenBriefingKeyCode: Int = 7  // kVK_ANSI_X

    @AppStorage("briefingHotkeyOpenBriefingModifiers")
    var briefingHotkeyOpenBriefingModifiers: Int = 2048 // optionKey

    // MARK: - News feeds (JSON-encoded list of NewsFeedConfig)

    @AppStorage("briefingNewsFeedsJSON")
    var briefingNewsFeedsJSON: String = "[]"

    /// "08:00" — fetch news at this local time. Empty disables auto fetch.
    @AppStorage("briefingNewsFetchTime")
    var briefingNewsFetchTime: String = "08:00"

    /// How many times per day to refresh news. 1 = once at fetch time.
    @AppStorage("briefingNewsFetchesPerDay")
    var briefingNewsFetchesPerDay: Int = 1

    /// Comma-separated "HH:mm" times at which the briefing auto-runs.
    /// Persisted in addition to the cron expression so the Settings UI can
    /// show a friendly time-picker; cron is regenerated from this on save.
    @AppStorage("briefingScheduleTimes")
    var briefingScheduleTimes: String = "08:33"

    /// Free-form markdown the user pastes to steer the briefing summariser
    /// — e.g. "tập trung vào việc kỹ thuật, bỏ qua marketing". Persisted
    /// to a file the Go briefing runner reads so Claude's prompt sees it
    /// as a "# Ưu tiên người dùng" section.
    @AppStorage("briefingUserPrompt")
    var briefingUserPrompt: String = ""

    /// Per-MCP-connector markdown prompts. JSON encoded shape of
    /// `MCPConnectorPrompts` (slack / clickup / gdrive / gmail / gcal /
    /// gsheets). Same file-bridge pattern as briefingUserPrompt — the Go
    /// briefing runner reads them on each run.
    @AppStorage("mcpConnectorPromptsJSON")
    var mcpConnectorPromptsJSON: String = "{}"

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

    /// Display name shown in the Daily window's top-left profile chip.
    /// Empty falls back to "Bạn" so the chip still renders something readable.
    @AppStorage("dailyProfileName") var dailyProfileName: String = ""

    /// Absolute path to the user-selected avatar PNG copied into
    /// `~/Library/Application Support/claude-swap-widget/avatar.png`.
    /// Empty means use the initial-letter placeholder.
    @AppStorage("dailyProfileAvatarPath") var dailyProfileAvatarPath: String = ""

    /// Bumped every time the avatar file is rewritten so SwiftUI views observing
    /// this counter re-decode the on-disk image without us mutating its URL.
    @AppStorage("dailyProfileAvatarVersion") var dailyProfileAvatarVersion: Int = 0

    /// Parsed view of `reloadShortcut`, with default fallback if the stored
    /// string is malformed (e.g. user-edited UserDefaults).
    var parsedReloadShortcut: KeyboardShortcut {
        KeyboardShortcut.parse(reloadShortcut) ?? .defaultShortcut
    }
}

enum WidgetTheme: String, CaseIterable, Identifiable {
    case light, dark, rainbow, apple

    var id: String { rawValue }

    var isDark: Bool { self == .dark }

    var next: WidgetTheme {
        switch self {
        case .light:   return .dark
        case .dark:    return .rainbow
        case .rainbow: return .apple
        case .apple:   return .light
        }
    }

    // MARK: Colors

    /// True when the popover should paint vibrancy (`.menuBar` material) instead
    /// of a flat `background` fill. Read by `WidgetTabbedPopover` so the rest of
    /// the theme API stays Color-based.
    var useVibrancy: Bool { self == .apple }

    var background: Color {
        switch self {
        case .light:   return .white
        case .dark:    return Color(white: 0.14)
        case .rainbow: return Color(red: 0.99, green: 0.95, blue: 1.0)
        case .apple:   return .clear   // vibrancy material applied at popover root
        }
    }

    var activeAccent: Color {
        switch self {
        case .light, .dark: return .green
        case .rainbow:      return Color(red: 0.75, green: 0.2, blue: 0.85)
        case .apple:        return Color(nsColor: .systemGreen)
        }
    }

    var activeChipBackground: Color {
        switch self {
        case .light, .dark: return .green
        case .rainbow:      return Color(red: 0.85, green: 0.15, blue: 0.65)
        case .apple:        return Color(nsColor: .systemGreen)
        }
    }

    var sectionHeaderColor: Color {
        switch self {
        case .light, .dark: return .secondary
        case .rainbow:      return Color(red: 0.6, green: 0.2, blue: 0.8)
        case .apple:        return .secondary
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
