import AppKit

/// Window-level pointing-hand cursor manager for the Settings panel.
///
/// SwiftUI buttons don't get a hand cursor on macOS by default. Instead
/// of decorating every `Button` / `Toggle` / `Picker` site across the
/// Settings tabs with `.pointingHandCursor()`, we install ONE event
/// monitor on the Settings NSWindow that hit-tests the cursor's current
/// position and sets the pointing-hand cursor whenever it lands on an
/// interactive control or any of its SwiftUI-bridged ancestors.
///
/// Why this exists: 50+ Buttons across General / MCP / Update / About /
/// Diagnostics / Briefing / Privacy tabs would all otherwise need the
/// modifier. Adding it at the AppKit window level catches every
/// existing site AND any future Button we add, with no per-site code
/// to maintain.
///
/// The tracker is paired 1:1 with the Settings window — it lives for
/// the lifetime of the window and tears down via `windowWillClose`.
@MainActor
final class SettingsCursorTracker: NSObject {
    private weak var window: NSWindow?
    private var monitor: Any?
    private var lastCursorWasHand = false

    /// Install on the given window. Only call once per window; calling
    /// twice would stack monitors and cause every mouseMoved to be
    /// handled multiple times.
    static func install(on window: NSWindow) -> SettingsCursorTracker {
        let tracker = SettingsCursorTracker()
        tracker.window = window
        // Without this, NSWindow drops mouseMoved events entirely —
        // we never get the chance to set a cursor.
        window.acceptsMouseMovedEvents = true
        // Local monitor: receives every mouseMoved that hits this app
        // before any NSResponder. Returning the event unmodified lets
        // existing handlers (NSButton hover, etc) run unaffected.
        tracker.monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak tracker] event in
            tracker?.handle(event)
            return event
        }
        return tracker
    }

    /// Tear down the event monitor. Call from windowWillClose so the
    /// tracker doesn't outlive its window and keep firing for global
    /// mouse moves.
    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if lastCursorWasHand {
            NSCursor.arrow.set()
            lastCursorWasHand = false
        }
    }

    /// Hit-test the cursor's position; set pointing-hand if the
    /// resulting view (or any ancestor) is an interactive control,
    /// otherwise restore the arrow.
    private func handle(_ event: NSEvent) {
        guard let window, event.window === window, let contentView = window.contentView else {
            return
        }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else {
            return
        }
        let interactive = Self.isInteractive(hit)
        if interactive && !lastCursorWasHand {
            NSCursor.pointingHand.set()
            lastCursorWasHand = true
        } else if !interactive && lastCursorWasHand {
            NSCursor.arrow.set()
            lastCursorWasHand = false
        }
    }

    /// Walk the responder chain from the hit view upward, matching
    /// class names against patterns SwiftUI uses for its bridged
    /// controls. The class-name fallback is necessary because SwiftUI
    /// often bridges `Button` to a private hosting class rather than a
    /// public `NSButton` — we can't `is NSButton` our way through.
    /// Plus matches: `NSControl` (covers segmented controls, popup
    /// buttons, switches), and any class name containing Button /
    /// Toggle / Switch / Picker / Link.
    private static func isInteractive(_ view: NSView) -> Bool {
        var v: NSView? = view
        var depth = 0
        while let cur = v, depth < 12 {
            if cur is NSControl {
                return true
            }
            let cls = String(describing: type(of: cur))
            if cls.contains("Button")
                || cls.contains("Toggle")
                || cls.contains("Switch")
                || cls.contains("Picker")
                || cls.contains("Link")
                || cls.contains("Stepper") {
                return true
            }
            v = cur.superview
            depth += 1
        }
        return false
    }
}
