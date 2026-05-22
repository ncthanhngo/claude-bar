import SwiftUI

/// Slider with a "current usage" marker so the user sees how close they
/// are to the auto-swap trigger.
struct ThresholdSliderView: View {
    @Binding var threshold: Int
    let currentPct: Int?
    var isEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    track(geo)
                    fill(geo)
                    if let pct = currentPct {
                        currentMarker(geo, pct: pct)
                    }
                    thresholdKnob(geo)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geo.size.width))
                .pointingHandCursor()
            }
            .frame(height: 22)
            legend
        }
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
    }

    // MARK: layers

    private func track(_ geo: GeometryProxy) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 4)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
    }

    private func fill(_ geo: GeometryProxy) -> some View {
        Capsule()
            .fill(thresholdColor)
            .frame(width: geo.size.width * fraction(threshold), height: 4)
            .position(x: geo.size.width * fraction(threshold) / 2,
                      y: geo.size.height / 2)
    }

    @ViewBuilder
    private func currentMarker(_ geo: GeometryProxy, pct: Int) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.55))
            .frame(width: 2, height: 14)
            .position(x: geo.size.width * fraction(pct), y: geo.size.height / 2)
    }

    private func thresholdKnob(_ geo: GeometryProxy) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(thresholdColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            .position(x: geo.size.width * fraction(threshold), y: geo.size.height / 2)
    }

    private var legend: some View {
        HStack {
            if let cur = currentPct {
                marker(text: "current \(cur)%", color: .primary.opacity(0.55), bold: false)
            }
            Spacer()
            marker(text: "trigger \(threshold)%", color: thresholdColor, bold: true)
        }
    }

    private func marker(text: String, color: Color, bold: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: bold ? .semibold : .regular))
                .monospacedDigit()
                .foregroundColor(bold ? color : .primary.opacity(0.6))
        }
    }

    // MARK: helpers

    private func fraction(_ pct: Int) -> CGFloat {
        CGFloat(max(1, min(100, pct))) / 100
    }

    private var thresholdColor: Color { UsagePalette.color(for: threshold) }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            let pct = Int((value.location.x / width * 100).rounded())
            threshold = max(1, min(100, pct))
        }
    }
}
