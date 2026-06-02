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
        // Pin Apple's frosted-glass theme to the light (.aqua) appearance so the
        // vibrancy material always renders as bright frosted glass. Following the
        // system instead made it dark/dim on machines in Dark Mode.
        case .apple:           window.appearance = NSAppearance(named: .aqua)
        }
    }
}
