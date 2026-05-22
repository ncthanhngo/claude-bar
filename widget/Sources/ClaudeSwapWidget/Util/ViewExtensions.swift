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
}
