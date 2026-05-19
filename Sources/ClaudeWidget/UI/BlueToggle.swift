import SwiftUI

/// Custom switch that always renders blue when on, gray when off — bypasses
/// macOS system accent color so users with Graphite/Multicolor accents still
/// see a clear ON-state cue. Visually similar to the native `.switch` style
/// but with hardcoded colors.
struct BlueToggle: View {
    @Binding var isOn: Bool

    private let trackWidth: CGFloat  = 36
    private let trackHeight: CGFloat = 20
    private let knobInset: CGFloat   = 2

    private static let onColor  = Color(red: 0.0,  green: 0.478, blue: 1.0)
    private static let offColor = Color(red: 0.78, green: 0.78,  blue: 0.80)

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Self.onColor : Self.offColor)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .padding(knobInset)
        }
        .frame(width: trackWidth, height: trackHeight)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .contentShape(Capsule())
        .onTapGesture { isOn.toggle() }
    }
}
