import Foundation
import SwiftUI

/// User-tweakable settings persisted via UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("autoSwapEnabled") var autoSwapEnabled: Bool = false
    @AppStorage("thresholdPct") var thresholdPct: Int = 90

    /// Master "pause" switch. When true the app stays in the menu bar and
    /// remains fully interactive (manual refresh, account switch, settings)
    /// but every background loop and helper process is torn down: usage
    /// polling, the 6-hour token refresh, auto-swap, the briefing scheduler,
    /// web cookie keep-alive, iCloud preference sync, and the gate-proxy
    /// subprocess. App Nap is allowed to re-engage too, so a paused app is as
    /// quiet as it was before it was installed. Persisted — a paused app
    /// relaunches paused until the user flips it back. Coordinated centrally
    /// by `BackgroundWorkController`.
    @AppStorage("dormantModeEnabled") var dormantModeEnabled: Bool = false

    /// Auto-recover a dead active credential without user action: swap to a
    /// healthy account (then silently repair the broken one) or, when no
    /// target is available, run a hidden re-login. Defaults on — recovering a
    /// broken login is the headline behaviour of this feature; the Settings
    /// toggle (Phase 7) lets users opt out. Gated independently of
    /// `autoSwapEnabled` so recovery and quota-swap can be toggled separately.
    @AppStorage("autoRecoverEnabled") var autoRecoverEnabled: Bool = true

    /// Grace (seconds) between the "swapping to recover" notification and the
    /// swap when an active credential dies and a healthy target exists.
    /// User-confirmed default 3s; the Cancel notification action is the safety
    /// valve for the short window.
    @AppStorage("credSwapDelaySec") var credSwapDelaySec: Int = 3
    /// Grace (seconds) before a hidden in-place re-login when no swap target
    /// exists. User-confirmed default 7s.
    @AppStorage("credReloginDelaySec") var credReloginDelaySec: Int = 7
    /// Refresh interval used when active 5h utilisation is below
    /// `adaptiveHighThresholdPct`. Default 180s (3 min).
    @AppStorage("refreshIntervalSec") var refreshIntervalSec: Int = 180

    /// Refresh interval used when active 5h utilisation is at or above
    /// `adaptiveHighThresholdPct`. Default 120s (2 min). Picked so the
    /// widget reacts faster as we approach the auto-swap threshold.
    @AppStorage("refreshIntervalHighSec") var refreshIntervalHighSec: Int = 120

    /// Cutoff (%) where we switch from "low" to "high" refresh frequency.
    @AppStorage("adaptiveHighThresholdPct") var adaptiveHighThresholdPct: Int = 80

    // Server monitor (popover Server tab).
    @AppStorage("serverPollIntervalMinutes") var serverPollIntervalMinutes: Int = 5
    @AppStorage("serverDiskWarnPct") var serverDiskWarnPct: Int = 85
    @AppStorage("serverDiskCritPct") var serverDiskCritPct: Int = 90
    /// When on, a host crossing the crit disk threshold raises a notification
    /// (default off — disk is display-only unless the user opts in).
    @AppStorage("serverDiskAlertsEnabled") var serverDiskAlertsEnabled: Bool = false

    // Claude status monitor (status.claude.com). Notifies every user on a
    // major+ Anthropic outage. Default ON — that's the point of the feature;
    // the toggle lets a user who finds it noisy opt out.
    @AppStorage("claudeStatusAlertsEnabled") var claudeStatusAlertsEnabled: Bool = true
    /// Poll cadence for the status page; tightened to 1 min automatically while
    /// an outage is live (see ClaudeStatusStore).
    @AppStorage("claudeStatusPollMinutes") var claudeStatusPollMinutes: Int = 5

    /// When true, opening the menu-bar popover triggers an immediate refresh
    /// and tightens the polling cadence for ~5 minutes so the chart stays
    /// fresh while in view. Turn off on laptops running on battery if the
    /// extra WKWebView scrapes feel costly — background polling still
    /// follows `refreshIntervalSec`.
    @AppStorage("popoverBoostEnabled") var popoverBoostEnabled: Bool = true

    /// When true, web-linked accounts that haven't been polled within the
    /// keep-alive window get an explicit refresh so the claude.ai session
    /// cookie doesn't lapse into server-side idle timeout. Useful when the
    /// regular poll cadence has been stretched (low traffic settings, many
    /// accounts) or when an account spent a long stretch in rate-limit
    /// backoff. Safe to turn off if you don't link web profiles.
    @AppStorage("cookieKeepAliveEnabled") var cookieKeepAliveEnabled: Bool = true
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

    /// Popover layout — Standard (full status, auto-swap, token chart) vs
    /// Minimum (header + account list only). Stored as the raw string so
    /// SwiftUI Picker tag(s) line up with @AppStorage directly without a
    /// custom RawRepresentable bridge.
    @AppStorage("popoverLayout") var popoverLayout: PopoverLayout = .standard

    /// Whether the Full popover shows the "Token usage" chart + KPI cards
    /// at the bottom. Off by default — the section adds ~220pt of height
    /// that most users don't need glance-able. Toggled from General → UI.
    @AppStorage("showTokenUsageInFullPopover") var showTokenUsageInFullPopover: Bool = false

    /// Token-usage chart style in the Full popover — Wave (area chart) or
    /// Calendar (GitHub-style heatmap). Chosen in Settings → General; the
    /// popover renders whichever is selected (no in-popover switcher).
    @AppStorage("tokenChartStyle") var tokenChartStyle: TokenChartStyle = .wave

    // MARK: - Daily Briefing scheduler + quiet hours

    @AppStorage("briefingScheduleMode") var briefingScheduleMode: String = "cron"
    @AppStorage("briefingIntervalMinutes") var briefingIntervalMinutes: Int = 15
    @AppStorage("quietHoursStart") var quietHoursStart: String = "22:00"
    @AppStorage("quietHoursEnd") var quietHoursEnd: String = "07:00"

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

    /// Tool-permission level for the in-app chat ("Hỏi gì đó với Claude…").
    /// Read by `ChatStreamReader` and forwarded to the Go chat client via the
    /// `CB_CHAT_TOOL_MODE` env var. Three tiers: `.off` (no tools / no skills,
    /// safest), `.safe` (read-only + MCP + skills, no Bash/Write/Edit), `.full`
    /// (everything, equivalent to `--dangerously-skip-permissions`).
    @AppStorage("chatToolMode") var chatToolMode: ChatToolMode = .safe

    /// Flipped to true once the first-launch onboarding wizard's Finish
    /// button is clicked. The wizard never reappears while this is true;
    /// the "Re-run onboarding" action in the About tab flips it back.
    @AppStorage("didCompleteOnboarding") var didCompleteOnboarding: Bool = false

    /// Per-MCP-connector markdown prompts. JSON encoded shape of
    /// `MCPConnectorPrompts` (slack / clickup / gdrive / gmail / gcal /
    /// gsheets). Read by the Go side on chat-tool invocations.
    @AppStorage("mcpConnectorPromptsJSON")
    var mcpConnectorPromptsJSON: String = "{}"

    /// When true, `cb_slack_post_message` skips the local write approval
    /// popover. Other Slack write tools and all non-Slack write tools stay
    /// gated. Defaults to `true`; user can opt out via Local MCP settings.
    /// App.init() seeds the UserDefaults key to true on first launch so
    /// existing installs that pre-date the default flip also get it on
    /// without overriding any choice the user has actively made.
    @AppStorage("autoApproveSlackPostMessage") var autoApproveSlackPostMessage: Bool = true

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

    /// Timestamp of the last automatic iCloud pull→refresh→push cycle attempt
    /// (written at start of each cycle). Surfaced in Diagnostics so the user
    /// can see whether background sync is actually running even though
    /// pullQuiet/pushQuiet swallow individual errors.
    @AppStorage("lastAutoSyncAt") var lastAutoSyncAt: Double = 0

    /// Timestamp of the most recent fully-successful auto-sync cycle (pull +
    /// refresh + push all returned ok). Drives the "Last sync Xh ago" / red
    /// "Sync failing" badge — a wide gap means the user should investigate
    /// (wrong passphrase, iCloud Drive disabled, disk full…).
    @AppStorage("lastAutoSyncSuccessAt") var lastAutoSyncSuccessAt: Double = 0

    /// Short one-line failure reason captured from the last cycle when the
    /// success timestamp didn't move. Empty when the last cycle succeeded or
    /// no cycle has run yet. Surfaced as the secondary text on the sync chip.
    @AppStorage("lastAutoSyncError") var lastAutoSyncError: String = ""

    /// Master switch for iCloud cloud-sync. When false, every call into
    /// `loadPassphrase()` short-circuits to nil — the app never reads the
    /// Keychain item, so a freshly-signed Sparkle build doesn't trigger the
    /// macOS "Allow ClaudeBar to access this keychain item?" ACL prompt on
    /// first run after each update. Defaults to off for every install (no
    /// auto-migration) — users who want sync flip the toggle in Diagnostics.
    @AppStorage("iCloudSyncEnabled") var iCloudSyncEnabled: Bool = false

    /// `CFBundleShortVersionString` from the last launch. On every fresh
    /// install or version bump the launch code compares this against the
    /// running version and, if they differ, force-resets `iCloudSyncEnabled`
    /// to false. The intent is that every Sparkle update lands on a clean
    /// default-off — users who want sync re-enable it once per release and
    /// it persists for all launches at that version. Empty on first run.
    @AppStorage("lastLaunchedAppVersion") var lastLaunchedAppVersion: String = ""

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

/// Visual density of the menu-bar popover, from largest to smallest.
///
/// **Full** — the full dashboard: status header, accounts with usage bars,
/// auto-swap slider, token-usage chart. For people who drive auto-swap and
/// watch quota burn live.
///
/// **Standard** — 2/3-scaled compact dashboard: account rows with twin
/// 5h/7d bars, plus small auto-swap and token KPI cards. No slider, no
/// chart. The default for new installs.
///
/// **Tiny** — header + account list only. Each row: avatar + name +
/// ACTIVE dot + tiny 5h/7d percentage chips. The smallest popover the
/// app ships.
///
/// ## Migration
/// Raw values renamed in v10.38 to disambiguate the user-visible labels
/// from their internal meaning. The old enum was `(standard, medium,
/// tiny)`; "standard" meant the full dashboard back then. Custom
/// `init?(rawValue:)` maps the historical strings forward so nobody gets
/// bumped to a different layout on update:
///   • `"standard"`           (old: full dashboard) → `.full`
///   • `"medium"`, `"minimum"` (old: compact)       → `.standard`
///   • `"standard_v2"`        (new write)           → `.standard`
///   • `"full"`, `"tiny"`     (already canonical)   → as-is
///
/// `.standard` writes the new rawValue `"standard_v2"` so it can never
/// collide with the old `"standard"` meaning.
enum PopoverLayout: String, CaseIterable, Identifiable {
    case full
    case standard = "standard_v2"
    case tiny

    var id: String { rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "full", "standard":                   self = .full
        case "standard_v2", "medium", "minimum":   self = .standard
        case "tiny":                               self = .tiny
        default:                                   return nil
        }
    }

    var label: String {
        switch self {
        case .full:     return "Full"
        case .standard: return "Standard"
        case .tiny:     return "Tiny"
        }
    }

    var detail: String {
        switch self {
        case .full:     return "Status header + accounts with usage bars + auto-swap slider + token chart."
        case .standard: return "Compact accounts with 5h/7d bars + small auto-swap and token KPI cards."
        case .tiny:     return "Header + account list with tiny 5h/7d % chips. Tap to switch."
        }
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
        // Green across every theme — the "this is the live account" cue is
        // load-bearing enough that we don't want it shifting hue per theme.
        // Rainbow used to lean purple/magenta; that read as a decorative
        // accent, not "active". One colour, everywhere.
        switch self {
        case .apple: return Color(nsColor: .systemGreen)
        default:     return .green
        }
    }

    var activeChipBackground: Color {
        switch self {
        case .apple: return Color(nsColor: .systemGreen)
        default:     return .green
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

/// Tool-permission tier for in-app chat. Wire-format string is the same value
/// passed through the `CB_CHAT_TOOL_MODE` env var so the Go backend can
/// switch on it without knowing about Swift enums.
enum ChatToolMode: String, CaseIterable, Identifiable {
    case off
    case safe
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:  return "Chat only — no tools"
        case .safe: return "Read + MCP + skills (recommended)"
        case .full: return "Full agent — bash, write files, run commands"
        }
    }

    var subtitle: String {
        switch self {
        case .off:
            return "Claude only replies with text. No skills, no MCP, no file access."
        case .safe:
            return "Lets Claude read files (Read/Glob/Grep), browse the web (WebFetch/WebSearch), use any MCP server (Slack/Gmail/Drive/Calendar/ClickUp…), and run slash commands (skills). No Bash/Write/Edit, so Claude can't run shell commands or change your files."
        case .full:
            return "All tools enabled, including Bash, Write, and Edit. Claude runs from $HOME, so it can read and write any file in your home folder and run shell commands. All confirmations are skipped — a prompt injection could destroy data."
        }
    }

    /// Severity badge: 0 = safe, 1 = caution, 2 = danger.
    var riskTier: Int {
        switch self {
        case .off:  return 0
        case .safe: return 1
        case .full: return 2
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
