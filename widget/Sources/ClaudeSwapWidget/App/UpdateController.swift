import SwiftUI
import Sparkle

/// SwiftUI-friendly wrapper around Sparkle's `SPUStandardUpdaterController`.
/// Owned by the app root so the embedded `SPUUpdater` lives for the entire
/// session and the daily scheduled check fires reliably.
///
/// Update verification: every download is EdDSA-signed; Sparkle refuses to
/// install if the signature doesn't match `SUPublicEDKey` in Info.plist.
/// The signed appcast at `SUFeedURL` lists each release's signature.
@MainActor
final class UpdateController: ObservableObject {
    /// The actual Sparkle controller. nil when `SUPublicEDKey` in Info.plist
    /// is the placeholder string — we refuse to start the updater because
    /// every signature verification would fail and surface a daily error
    /// dialog. Once a real EdDSA public key replaces the placeholder, the
    /// controller initialises on next launch.
    let controller: SPUStandardUpdaterController?

    /// Whether the user can currently invoke "Check for updates…".
    /// False when the controller didn't start (placeholder pubkey).
    @Published private(set) var canCheck: Bool = false

    /// Surfaced in About so the UI can explain WHY updates are disabled
    /// instead of silently disabling the button.
    let placeholderKey: Bool

    init() {
        let pub = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let isPlaceholder = pub.isEmpty || pub.hasPrefix("REPLACE_WITH_")
        self.placeholderKey = isPlaceholder
        if isPlaceholder {
            controller = nil
            canCheck = false
        } else {
            let c = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            controller = c
            canCheck = c.updater.canCheckForUpdates
        }
    }

    /// User-initiated update check from the About tab. No-op when the
    /// updater isn't running.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Bind to a SwiftUI Toggle in Settings → General. Mirrors Sparkle's
    /// `UserDefaults`-backed `SUEnableAutomaticChecks` so the setting
    /// survives relaunches. No-op when the updater isn't running.
    var automaticChecksEnabled: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
