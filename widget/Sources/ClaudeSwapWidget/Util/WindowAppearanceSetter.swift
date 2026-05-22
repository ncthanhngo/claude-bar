import SwiftUI
import AppKit

/// Sets NSWindow.appearance directly so dark/light theme applies to the
/// entire MenuBarExtra panel (window chrome + SwiftUI colors).
struct WindowAppearanceSetter: NSViewRepresentable {
    let theme: WidgetTheme

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // Also try to set on first render (window may already exist)
        DispatchQueue.main.async { apply(to: v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        switch theme {
        case .light, .rainbow: window.appearance = NSAppearance(named: .aqua)
        case .dark:            window.appearance = NSAppearance(named: .darkAqua)
        case .apple:           window.appearance = nil  // follow system appearance
        }
    }
}
