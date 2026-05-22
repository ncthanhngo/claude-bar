import SwiftUI
import AppKit

// AppKit-backed vibrancy background. SwiftUI's `.regularMaterial` ShapeStyle
// renders as a CALayer with blur but has occasional layout quirks inside
// `MenuBarExtra` popovers (children collapse to zero height after async data
// loads). `NSVisualEffectView` is the platform-blessed way to paint the same
// effect and is what AppKit menu-bar items have always used.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}
