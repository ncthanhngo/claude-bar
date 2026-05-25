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
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    private static let behavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    static func configure(_ window: NSWindow) {
        window.level = level
        window.collectionBehavior = behavior
    }

    @discardableResult
    static func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        configure(alert.window)
        return alert.runModal()
    }

    @discardableResult
    static func runPanel(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        configure(panel)
        return panel.runModal()
    }
}
