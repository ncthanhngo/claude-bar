import SwiftUI
import AppKit

/// Holds a weak reference to the menu-bar popover NSWindow once SwiftUI
/// mounts `WidgetTabbedPopover` for the first time. Lets non-SwiftUI code
/// (BriefingCoordinator, MenuBarPopoverToggle) ask "is the popover visible?"
/// and "close the popover" without poking at NSStatusBarButton.state, which
/// SwiftUI's MenuBarExtra does not keep in sync with popover visibility.
@MainActor
final class PopoverWindowRegistry {
    static let shared = PopoverWindowRegistry()
    weak var window: NSWindow?
    private init() {}
}

/// Drop-in `.background(PopoverWindowCapture())` on the popover root view —
/// records its hosting NSWindow into the registry on first mount.
struct PopoverWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { capture(from: v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if PopoverWindowRegistry.shared.window == nil { capture(from: nsView) }
    }

    private func capture(from view: NSView) {
        guard let w = view.window else { return }
        PopoverWindowRegistry.shared.window = w
    }
}
