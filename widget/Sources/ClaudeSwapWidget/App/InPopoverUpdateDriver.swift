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
        // Auto-grant background checks; matches the SUEnableAutomaticChecks
        // value we ship in Info.plist, so no interactive prompt is needed.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelCheckHandler = cancellation
        stage = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                        state: SPUUserUpdateState,
                        reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelCheckHandler = nil
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
        stage = .downloading(progress: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength
        receivedDownloadLength = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadLength &+= length
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
        stage = .extracting(progress: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        stage = .extracting(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installReply = reply
        stage = .readyToInstall
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        retryTerminationHandler = retryTerminatingApplication
        stage = .installing
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
