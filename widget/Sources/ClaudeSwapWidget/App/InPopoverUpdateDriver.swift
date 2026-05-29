import AppKit
import Foundation
import Sparkle

/// Custom Sparkle user driver that surfaces the entire update flow as a
/// SwiftUI overlay INSIDE the menu-bar popover, instead of opening
/// Sparkle's default external NSWindow.
///
/// Why: the standard driver opens its own window, which steals key status
/// from the popover. SwiftUI MenuBarExtra(.window) auto-dismisses the
/// popover when it loses key — so the user clicks "Check for updates…",
/// the popover snaps shut, and a separate update panel appears somewhere
/// else on screen. Rendering the flow inside the popover keeps focus
/// where the click started, the panel sits centred over the popover
/// (because it IS the popover), and the popover only dismisses on the
/// normal outside-click rule.
@MainActor
final class InPopoverUpdateDriver: NSObject, ObservableObject, SPUUserDriver {
    /// Single source of truth the SwiftUI overlay observes. Each Sparkle
    /// callback maps to one of these cases; the overlay branches on
    /// `stage` to pick the right card.
    enum Stage: Equatable {
        case idle
        case checking
        case foundUpdate(version: String, notes: String?)
        case downloading(progress: Double)
        case extracting(progress: Double)
        case readyToInstall
        case installing
        case upToDate
        case error(String)
    }

    @Published private(set) var stage: Stage = .idle

    /// Mirror of UpdateController.autoUpdateEnabled — set from the
    /// controller, read here to decide whether to auto-reply on Sparkle
    /// prompts. When ON and the check was started by Sparkle's scheduler
    /// (not a manual "Check for updates…" click), we skip the "Update
    /// available" + "Ready to install" cards and tell Sparkle to install
    /// immediately. User-initiated checks still get the full flow so
    /// nothing surprises someone who clicked the button on purpose.
    var autoUpdateEnabled: Bool = false

    // Closures handed to us by Sparkle — we invoke them when the user
    // clicks the corresponding button on the overlay card.
    private var cancelCheckHandler: (() -> Void)?
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var downloadCancelHandler: (() -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var ackHandler: (() -> Void)?
    private var retryTerminationHandler: (() -> Void)?

    // Download progress accounting — Sparkle reports incremental bytes.
    private var expectedDownloadLength: UInt64 = 0
    private var receivedDownloadLength: UInt64 = 0

    // MARK: - User actions (called from the SwiftUI overlay)

    /// User clicked the primary button on the "Update available" card.
    func userTappedInstall() {
        if let reply = foundReply {
            foundReply = nil
            reply(.install)
            return
        }
        if let reply = installReply {
            installReply = nil
            reply(.install)
        }
    }

    /// User clicked "Later" — dismiss the prompt but keep the popover open.
    func userTappedLater() {
        if let reply = foundReply {
            foundReply = nil
            reply(.dismiss)
        } else if let reply = installReply {
            installReply = nil
            reply(.dismiss)
        }
        stage = .idle
    }

    /// User clicked "Skip this version".
    func userTappedSkip() {
        if let reply = foundReply {
            foundReply = nil
            reply(.skip)
        }
        stage = .idle
    }

    /// User clicked "Cancel" while a check was in flight.
    func userTappedCancelCheck() {
        cancelCheckHandler?()
        cancelCheckHandler = nil
        stage = .idle
    }

    /// User clicked "Cancel" while a download was in flight.
    func userTappedCancelDownload() {
        downloadCancelHandler?()
        downloadCancelHandler = nil
        stage = .idle
    }

    /// User clicked the OK / dismiss button on a terminal card (up-to-date,
    /// error, etc.). Releases Sparkle's acknowledgement closure.
    func userTappedAcknowledge() {
        ackHandler?()
        ackHandler = nil
        stage = .idle
    }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // We surface our own toggle in Settings → General (autoUpdateEnabled
        // on UpdateController) so Sparkle's first-run permission popup is
        // redundant. Reply with whatever the user already chose — true on
        // first launch (we default auto-update ON) or whatever they flipped
        // to since.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: autoUpdateEnabled, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelCheckHandler = cancellation
        stage = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                        state: SPUUserUpdateState,
                        reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelCheckHandler = nil
        // Silent flow when auto-update is ON and Sparkle's scheduler (not
        // the user) discovered the new version. We jump straight to
        // .install so Sparkle starts downloading without an "Update
        // available" card; the showReady callback below then auto-installs
        // when the download finishes. Skips the popover entirely.
        if autoUpdateEnabled && state.userInitiated == false {
            reply(.install)
            return
        }
        foundReply = reply
        let version = appcastItem.displayVersionString
        stage = .foundUpdate(version: version, notes: nil)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Best-effort: decode UTF-8 / HTML release notes and attach to the
        // foundUpdate stage. If decoding fails just leave the card as-is.
        guard case let .foundUpdate(version, _) = stage,
              let notes = String(data: downloadData.data, encoding: .utf8) else { return }
        stage = .foundUpdate(version: version, notes: notes)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Non-fatal — just keep the existing card.
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancelCheckHandler = nil
        ackHandler = acknowledgement
        stage = .upToDate
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        ackHandler = acknowledgement
        stage = .error(error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadCancelHandler = cancellation
        expectedDownloadLength = 0
        receivedDownloadLength = 0
        // Stay invisible when auto-update is doing its quiet thing — the
        // user didn't ask for a download UI right now. We still hang onto
        // the cancellation closure in case the controller wants to cancel
        // for any reason later. The .idle stage means the overlay does
        // not render anything during the download.
        if autoUpdateEnabled {
            stage = .idle
            return
        }
        stage = .downloading(progress: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength
        receivedDownloadLength = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadLength &+= length
        if autoUpdateEnabled { return }
        let p: Double
        if expectedDownloadLength > 0 {
            p = min(1.0, Double(receivedDownloadLength) / Double(expectedDownloadLength))
        } else {
            p = 0
        }
        stage = .downloading(progress: p)
    }

    func showDownloadDidStartExtractingUpdate() {
        downloadCancelHandler = nil
        if autoUpdateEnabled { return }
        stage = .extracting(progress: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if autoUpdateEnabled { return }
        stage = .extracting(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Auto-update path: relaunch silently. Claude Bar is a menu-bar
        // utility — no editor state to save, no document the user can lose
        // — so a quiet relaunch is the desired UX, not a surprise. Users
        // who manually triggered the check still get the install card so
        // their click leads to a visible outcome.
        if autoUpdateEnabled {
            reply(.install)
            return
        }
        installReply = reply
        stage = .readyToInstall
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        retryTerminationHandler = retryTerminatingApplication
        stage = .installing
        // Pre-#20: nothing in this app responded to the install-and-relaunch
        // signal, so after the installer extracted the new bundle the host
        // process just sat there. Sparkle's installer waits for the host
        // PID to exit before swapping bundles + relaunching — without an
        // explicit terminate the user saw a "loading" menu-bar icon for
        // 10–20 minutes until some incidental runloop event (e.g. clicking
        // the icon) nudged it. Quit ourselves so Sparkle's TerminationListener
        // fires immediately and the new build launches right away.
        guard !applicationTerminated else { return }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // In practice the app has just relaunched, so this branch usually
        // doesn't render. Auto-ack so Sparkle can tear down cleanly.
        acknowledgement()
        stage = .idle
    }

    func showUpdateInFocus() {
        // Bring the popover to the front so an in-flight check is visible
        // again if the user toggled away. The popover NSWindow is our
        // "update UI" because the overlay lives inside it.
        if let w = PopoverWindowRegistry.shared.window {
            w.makeKeyAndOrderFront(nil)
        }
    }

    func dismissUpdateInstallation() {
        cancelCheckHandler = nil
        foundReply = nil
        downloadCancelHandler = nil
        installReply = nil
        ackHandler = nil
        retryTerminationHandler = nil
        stage = .idle
    }
}
