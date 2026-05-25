import AppKit

/// Centralised configuration for alerts and file panels presented from the
/// menu-bar popover. macOS gives both NSAlert and NSOpenPanel/NSSavePanel two
/// unhelpful defaults when shown from a status-bar app:
///
/// 1. **Level** is `.modalPanel` (8), well below the popover's `.popUpMenu`
///    (101) — so the dialog appears *behind* the popover the user just
///    clicked. The cursor lands on a popover button, a dialog spawns, but
///    the user can't see or interact with it.
/// 2. **collectionBehavior** is empty, so the modal anchors to whichever
///    Space holds the app's "main" window (usually the Daily window pinned
///    to its origin Space). With multiple desktops/Spaces, clicking a
///    popover button can yank the user to a different desktop instead of
///    showing the dialog where they are.
///
/// `configure(_:)` sets level above the popover and adds `.moveToActiveSpace`
/// so the dialog appears on the desktop the user is on, on top of the
/// popover that triggered it. `runAlert` / `runPanel` are the one-call
/// wrappers — touching `alert.window` triggers lazy NSPanel creation so the
/// level is set before macOS displays the window.
@MainActor
enum PopoverModal {
    /// One step above Settings window level (popUpMenu+1) so alerts/panels
    /// triggered from inside Settings sit ABOVE Settings, not behind it.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
    private static let behavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    static func configure(_ window: NSWindow) {
        window.level = level
        window.collectionBehavior = behavior
    }

    @discardableResult
    static func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        configure(alert.window)
        // Make the alert appear centered on the Settings window if it's
        // currently visible, rather than at the geometric center of the
        // screen. Without this, an alert triggered from Settings can land
        // off to the side and feel disconnected from the click target.
        centerOverSettingsWindowIfVisible(alert.window)
        return alert.runModal()
    }

    @discardableResult
    static func runPanel(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        configure(panel)
        centerOverSettingsWindowIfVisible(panel)
        return panel.runModal()
    }

    private static func centerOverSettingsWindowIfVisible(_ window: NSWindow) {
        guard let target = settingsWindow() else { return }
        // layoutIfNeeded so the alert/panel has its final size before we
        // compute the centered origin — otherwise width/height read as 0.
        window.layoutIfNeeded()
        let size = window.frame.size
        let tFrame = target.frame
        let origin = NSPoint(
            x: tFrame.midX - size.width / 2,
            y: tFrame.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private static func settingsWindow() -> NSWindow? {
        // Title-match is good enough — SettingsWindowController is the only
        // window with this title and only ever exists once.
        NSApp.windows.first { $0.title == "Claude Bar Settings" && $0.isVisible }
    }
}
