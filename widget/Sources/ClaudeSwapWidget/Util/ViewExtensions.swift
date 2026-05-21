import SwiftUI
import AppKit

// NSTrackingArea-based cursor overlay.
//
// Cursor rects require the view to pass hit-testing, which blocks SwiftUI
// gestures (DragGesture, Button tap) underneath. NSTrackingArea mouseEntered/
// mouseExited events are dispatched directly to the owner by NSWindow based
// on cursor geometry — they bypass hit-testing entirely, so we can return nil
// from hitTest and still receive cursor tracking notifications.
private struct PointingHandCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ v: TrackingView, context: Context) { v.updateTrackingAreas() }

    final class TrackingView: NSView {
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let old = trackingArea { removeTrackingArea(old) }
            let new = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(new)
            trackingArea = new
        }

        override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.push() }
        override func mouseExited(with event: NSEvent)  { NSCursor.pop() }

        // Pass all mouse events through so SwiftUI gestures underneath are not blocked.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        overlay(PointingHandCursorArea())
    }

    @ViewBuilder
    func pointingHandCursor(when condition: Bool) -> some View {
        if condition {
            overlay(PointingHandCursorArea())
        } else {
            self
        }
    }
}
