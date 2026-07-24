import AppKit
import SwiftUI

/// Hosts the server-management UI in a floating NSWindow.
///
/// A SwiftUI `.sheet` attached to the MenuBarExtra popover dismisses the whole
/// popover on focus loss (same class of bug the Add-account / Rename flows hit),
/// so the settings form could never be edited. FloatingWindow decouples it from
/// the popover entirely — the form owns its own state and outlives the popover.
@MainActor
final class ServerSettingsWindowController {
    static let shared = ServerSettingsWindowController()

    private let window = FloatingWindow<AnyView>()

    private init() {}

    /// Open the server-management window bound to the shared monitor store.
    func present(monitor: ServerMonitorStore) {
        let close: () -> Void = { [window] in window.close() }
        window.show(title: "Quản lý server", size: NSSize(width: 460, height: 520)) {
            AnyView(ServerSettingsSheet(onClose: close).environmentObject(monitor))
        }
        // MenuBarExtra collapses its popover when another window becomes key.
        // Re-open it behind the settings window (same fan-out the Rename flow
        // uses) so the user keeps the popover context after closing.
        let restoreDelays: [TimeInterval] = [0.05, 0.15, 0.3, 0.5]
        for delay in restoreDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MenuBarPopoverToggle.openIfClosed()
            }
        }
    }
}
