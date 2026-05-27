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
/// records its hosting NSWindow into the registry on first mount, and
/// relocates the popover to the cursor's display when SwiftUI placed it on
/// a different screen.
///
/// SwiftUI MenuBarExtra anchors the popover to the underlying NSStatusItem
/// button, which lives on one specific screen (whichever screen macOS
/// considers "the menu bar screen"). With extended/duplicate displays —
/// or when the popover is triggered by global hotkey while the user is on
/// the secondary display — that anchor screen often isn't the screen the
/// user is looking at, so the popover appears on the wrong display.
struct PopoverWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            capture(from: v)
            relocateToCursorScreenIfNeeded()
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-run capture every body update: weak ref can go nil after the
        // popover NSWindow is recycled (e.g. after a display reconfiguration),
        // and SwiftUI MenuBarExtra recreates the hosting window in that case.
        capture(from: nsView)
        DispatchQueue.main.async { relocateToCursorScreenIfNeeded() }
    }

    private func capture(from view: NSView) {
        guard let w = view.window else { return }
        PopoverWindowRegistry.shared.window = w
        // Pin the popover above other app windows so opening Settings or
        // the Briefing panel doesn't push the menu-bar popover under them.
        // .floating is the right tier here — it sits above .normal
        // (Settings, Briefing, FloatingWindow sheets) but stays below
        // system modals + the actual menu bar. Set every capture call
        // because SwiftUI MenuBarExtra recreates the popover window on
        // display reconfiguration and the level resets to .normal.
        //
        // The check uses `== .normal` (not `!= .floating`) so callers
        // that temporarily boost the popover to a HIGHER level (e.g.
        // `MenuBarPopoverToggle.openIfClosedAbove` lifts it above
        // Settings for layout preview) don't get clobbered back to
        // .floating on the next SwiftUI body update.
        if w.level == .normal {
            w.level = .floating
        }
        // Hide the popover the moment the user clicks into another app —
        // .floating alone would keep us pinned over Chrome / Terminal /
        // Slack and steal pointer focus from whatever they actually want
        // to interact with. Matches Terminal.app and Cloudflare WARP's
        // menu-bar popovers, which dismiss on app deactivation. Next
        // menu-bar click re-renders the popover normally.
        w.hidesOnDeactivate = true
    }

    /// If the popover NSWindow opened on a different screen than the one
    /// containing the mouse cursor, slide it onto the cursor's screen.
    /// Mirrors the original top-right placement (just below the menu bar)
    /// so the window still looks anchored to the menu bar — just on the
    /// right monitor.
    private func relocateToCursorScreenIfNeeded() {
        guard let w = PopoverWindowRegistry.shared.window, w.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false)
        }) else { return }
        if let current = w.screen, current === target { return }

        // Preserve the right-edge inset from the source screen so the popover
        // sits at the same horizontal offset on the destination screen.
        var frame = w.frame
        let sourceVF = (w.screen ?? target).visibleFrame
        let rightInset = max(0, sourceVF.maxX - frame.maxX)
        let visible = target.visibleFrame
        frame.origin.x = visible.maxX - frame.width - rightInset
        frame.origin.y = visible.maxY - frame.height
        w.setFrame(frame, display: true)
    }
}
