import SwiftUI
import Sparkle

/// SwiftUI-friendly wrapper around Sparkle's `SPUUpdater`. Owned by the app
/// root so the embedded `SPUUpdater` lives for the entire session and the
/// daily scheduled check fires reliably.
///
/// Unlike `SPUStandardUpdaterController` we run a custom `SPUUserDriver`
/// (`InPopoverUpdateDriver`) so the entire update UI renders inside the
/// menu-bar popover. This keeps the popover key during the whole flow —
/// MenuBarExtra(.window) dismisses the popover the moment any other window
/// becomes key, so Sparkle's default external panel would snap the popover
/// shut every time the user clicked "Check for updates…".
///
/// Update verification: every download is EdDSA-signed; Sparkle refuses to
/// install if the signature doesn't match `SUPublicEDKey` in Info.plist.
@MainActor
final class UpdateController: ObservableObject {
    /// The driver SwiftUI binds to for the overlay UI. Always present so the
    /// overlay can be wired into the view tree once at app start.
    let driver: InPopoverUpdateDriver

    /// nil when `SUPublicEDKey` in Info.plist is the placeholder string —
    /// we refuse to start the updater because every signature verification
    /// would fail and surface a daily error dialog.
    private let updater: SPUUpdater?

    /// Whether the user can currently invoke "Check for updates…".
    @Published private(set) var canCheck: Bool = false

    /// Surfaced in About so the UI can explain WHY updates are disabled.
    let placeholderKey: Bool

    init() {
        let pub = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let isPlaceholder = pub.isEmpty || pub.hasPrefix("REPLACE_WITH_")
        self.placeholderKey = isPlaceholder
        let driver = InPopoverUpdateDriver()
        self.driver = driver

        if isPlaceholder {
            self.updater = nil
            self.canCheck = false
            return
        }

        let u = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: driver,
            delegate: nil
        )
        do {
            try u.start()
            self.updater = u
            self.canCheck = u.canCheckForUpdates
        } catch {
            // Starting failed (e.g. malformed appcast URL). Leave the
            // controller disabled rather than crashing — About will show
            // the standard "updates disabled" hint.
            self.updater = nil
            self.canCheck = false
        }
    }

    /// User-initiated update check from the About tab. No-op when the
    /// updater isn't running.
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Bind to a SwiftUI Toggle in Settings → General. Mirrors Sparkle's
    /// `UserDefaults`-backed `SUEnableAutomaticChecks` so the setting
    /// survives relaunches. No-op when the updater isn't running.
    var automaticChecksEnabled: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
}
