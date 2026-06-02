import Foundation

/// User-facing application name, read from the bundle's Info.plist so the
/// SAME code shows "Claude Bar" on the stable track and "AI Bar" on the
/// experimental track without a per-branch source edit.
///
/// Use this for anything the user reads (window titles, About, onboarding,
/// notifications, settings copy). Internal identifiers — the
/// `~/Library/Logs/ClaudeBar` log dir, Keychain service names, the
/// Application Support path, claude-watch shell markers — stay FIXED string
/// literals at their call sites: the two tracks intentionally share that
/// state, so those must not vary by display name.
enum AppInfo {
    /// CFBundleDisplayName, falling back to CFBundleName, then "Claude Bar".
    static let displayName: String = {
        let bundle = Bundle.main
        if let n = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !n.isEmpty {
            return n
        }
        if let n = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !n.isEmpty {
            return n
        }
        return "Claude Bar"
    }()

    /// Title used by the standalone Settings window. Centralised so the
    /// window's `title` and the `NSApp.windows.first { $0.title == … }`
    /// lookups that re-find it stay in lockstep.
    static var settingsWindowTitle: String { "\(displayName) Settings" }
}
