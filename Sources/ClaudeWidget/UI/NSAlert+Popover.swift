import AppKit

extension NSAlert {
    /// Run the alert modally, ensuring it renders above the menu-bar popover
    /// panel (which lives at `.floating`). Without this, the alert window
    /// appears behind the widget and the user cannot click its buttons.
    @discardableResult
    func runModalAbovePopover() -> NSApplication.ModalResponse {
        window.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return runModal()
    }
}
