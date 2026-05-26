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
                .pointingHandCursorRect(when: isEnabled)
                .gesture(dragGesture(width: geo.size.width))
            }
            .frame(height: 30)
            legend
        }
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Auto-swap threshold")
        .accessibilityValue("\(threshold) percent")
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { Double(threshold) },
                    set: { threshold = Int($0.rounded()) }
                ),
                in: 1...100
            )
            .accessibilityLabel("Auto-swap threshold")
        }
    }

    // MARK: layers

    private func track(_ geo: GeometryProxy) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 8)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
    }

    private func fill(_ geo: GeometryProxy) -> some View {
        Capsule()
            .fill(thresholdColor)
            .frame(width: geo.size.width * fraction(threshold), height: 8)
            .position(x: geo.size.width * fraction(threshold) / 2,
                      y: geo.size.height / 2)
    }

    @ViewBuilder
    private func currentMarker(_ geo: GeometryProxy, pct: Int) -> some View {
        // Orange + 4× thicker than the old 2pt hairline. The marker now
        // reads as "you are HERE" instead of a stray gridline next to the
        // threshold knob. Orange contrasts the accent-blue fill so the
        // user sees current vs trigger at a glance.
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.orange)
            .frame(width: 8, height: 20)
            .position(x: geo.size.width * fraction(pct), y: geo.size.height / 2)
    }

    private func thresholdKnob(_ geo: GeometryProxy) -> some View {
        // Wrap the knob in a Button so SwiftUI's hover detection fires
        // reliably (it doesn't on a bare positioned Shape — the outer
        // DragGesture absorbs mouse-moved events for the entire ZStack).
        // The action is empty; the parent's gesture still drives the
        // threshold via `.simultaneousGesture` so dragging from the knob
        // continues to work.
        Button(action: {}) {
            Circle()
                .fill(Color.white)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(thresholdColor, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
        .pointingHandCursor(when: isEnabled)
        .simultaneousGesture(dragGesture(width: geo.size.width))
        .position(x: geo.size.width * fraction(threshold), y: geo.size.height / 2)
    }

    private var legend: some View {
        HStack(spacing: 0) {
            if let cur = currentPct {
                // The "current X%" number uses the same traffic-light palette
                // as the usage bars in each account row above, so the slider
                // legend visually agrees with the per-account percentages
                // instead of fading into secondary grey. Fixed-width value
                // slot prevents the row from twitching as digit count
                // crosses 9→10 or 99→100 — every percentage rendered into
                // the same 30pt cell.
                marker(label: "current", value: cur, color: UsagePalette.color(for: cur), alignment: .leading)
            }
            Spacer(minLength: 0)
            marker(label: "trigger", value: threshold, color: thresholdColor, alignment: .trailing)
        }
    }

    private func marker(label: String, value: Int, color: Color, alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 4) {
            if alignment == .leading {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.primary.opacity(0.6))
            Text("\(value)%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(color)
                .frame(width: 30, alignment: alignment == .leading ? .leading : .trailing)
            if alignment == .trailing {
                Circle().fill(color).frame(width: 6, height: 6)
            }
        }
    }

    // MARK: helpers

    private func fraction(_ pct: Int) -> CGFloat {
        CGFloat(max(1, min(100, pct))) / 100
    }

    // Slider stays accent (blue) across the entire 1–100% range. We used to
    // shift fill + knob through the UsagePalette traffic-light gradient as
    // the user dragged the threshold up, but that visually overloaded the
    // control — the colour change implied "you've entered danger zone" when
    // really the user was just picking a config value. A single static
    // accent reads as "this is just a setting", not a live warning.
    private var thresholdColor: Color { .accentColor }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            let pct = Int((value.location.x / width * 100).rounded())
            threshold = max(1, min(100, pct))
        }
    }
}
