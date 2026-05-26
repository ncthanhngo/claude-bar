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

    /// User-facing toggle. When true Sparkle: (a) polls the appcast on its
    /// scheduled cadence (daily via SUScheduledCheckInterval), (b) downloads
    /// new builds silently in the background, (c) auto-installs the next
    /// time the app is idle so the user doesn't have to click through. When
    /// false: user must trigger every check + install from About manually.
    ///
    /// Backed by UserDefaults via @Published so the value survives relaunch
    /// and SwiftUI Toggles bind cleanly. The two Sparkle flags
    /// (`automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates`)
    /// are kept in lock-step here so we never end up in the bizarre state
    /// "check daily but don't download" — that just produces yet another
    /// silent prompt and is precisely what users opt out of by choosing
    /// auto-update.
    @Published var autoUpdateEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoUpdateEnabled, forKey: Self.autoUpdateKey)
            applyAutoUpdate(autoUpdateEnabled)
            driver.autoUpdateEnabled = autoUpdateEnabled
        }
    }

    private static let autoUpdateKey = "cb.autoUpdate.enabled"

    init() {
        let pub = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let isPlaceholder = pub.isEmpty || pub.hasPrefix("REPLACE_WITH_")
        self.placeholderKey = isPlaceholder
        let driver = InPopoverUpdateDriver()
        self.driver = driver

        // Default ON for first-launch — every Claude Bar release ships
        // EdDSA-signed via Sparkle, so the user is safer up-to-date than
        // pinned to an old build. Subsequent launches honour whatever the
        // user toggled.
        let storedAuto: Bool = {
            if UserDefaults.standard.object(forKey: Self.autoUpdateKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.autoUpdateKey)
        }()
        self.autoUpdateEnabled = storedAuto
        driver.autoUpdateEnabled = storedAuto

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
            // Apply the persisted preference AFTER start() — Sparkle resets
            // these flags during boot if the host's Info.plist disagrees,
            // so re-asserting here keeps user intent authoritative.
            applyAutoUpdate(storedAuto)
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

    private func applyAutoUpdate(_ on: Bool) {
        guard let u = updater else { return }
        u.automaticallyChecksForUpdates = on
        u.automaticallyDownloadsUpdates = on
    }
}
