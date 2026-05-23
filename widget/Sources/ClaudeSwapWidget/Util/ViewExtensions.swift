import SwiftUI
import AppKit

// Pointing-hand cursor on hover.
//
// Previous implementation used an NSTrackingArea overlay, but mouseExited
// sometimes never fires when SwiftUI removes/replaces the view mid-hover —
// leaving NSCursor stuck on pointingHand. Local `pushed` state guarantees
// push/pop balance per view; `onDisappear` cleans up if the view goes away
// while the cursor is still pushed.
private struct PointingHandCursorModifier: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !hovering && pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }

    @ViewBuilder
    func pointingHandCursor(when condition: Bool) -> some View {
        if condition {
            modifier(PointingHandCursorModifier())
        } else {
            self
        }
    }

    /// AppKit-native cursor overlay — wins against native NSControls
    /// (Toggle's NSSwitch, etc.) that install their own tracking areas and
    /// reset the cursor as soon as the mouse enters them. The SwiftUI
    /// `.onHover` + `NSCursor.push()` path loses that race; using
    /// `NSTrackingArea` with `.cursorUpdate` is independent of hit-testing
    /// and the overlay's NSView itself returns nil from hitTest so clicks
    /// fall through to whatever sits below.
    func pointingHandCursorRect() -> some View {
        overlay(CursorRectOverlay(cursor: .pointingHand))
    }

    @ViewBuilder
    func pointingHandCursorRect(when condition: Bool) -> some View {
        if condition {
            overlay(CursorRectOverlay(cursor: .pointingHand))
        } else {
            self
        }
    }
}

/// Transparent NSView that uses an `NSTrackingArea` with `.cursorUpdate` to
/// set the cursor at the AppKit layer. Layered as a `.overlay` whose NSView
/// returns nil from `hitTest`, so clicks fall through to siblings below
/// (e.g. NSSwitch under a Toggle) while the cursor is still managed here.
///
/// Why not `addCursorRect`: AppKit resolves cursor rects through hit-testing,
/// so a view that returns nil from hitTest is skipped. `NSTrackingArea` with
/// `.cursorUpdate` is independent of hit-testing — the owner receives the
/// `cursorUpdate(_:)` callback whenever the mouse moves into the tracked
/// rectangle, regardless of which view AppKit considers "topmost" for clicks.
private struct CursorRectOverlay: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectNSView {
        CursorRectNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: CursorRectNSView, context: Context) {
        nsView.cursor = cursor
    }
}

private final class CursorRectNSView: NSView {
    var cursor: NSCursor
    private var trackingArea: NSTrackingArea?

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Clicks fall through to underlying SwiftUI views (Toggle, draggable
    // slider track). We're cursor-only — never intercept interaction.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }
}
