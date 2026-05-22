import SwiftUI

/// One usage-window row (5h or 7d).
///
/// Layout: [label] [bar] [pct%] [reset]
/// Numbers are monospaced and right-aligned to fixed widths so they line up
/// across the two windows and across multiple accounts.
struct UsageBar: View {
    let label: String
    let window: UsageWindowDTO

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .leading)
            bar
            Text(window.percentInt < 1 ? "<1%" : "\(window.percentInt)%")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundColor(barColor)
                .frame(width: 42, alignment: .trailing)
            Text(window.resetLabel())
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.primary.opacity(0.55))
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(barColor)
                    .frame(width: max(3, geo.size.width * window.fractionForBar))
            }
        }
        .frame(height: 4)
    }

    private var barColor: Color { UsagePalette.color(for: window.percentInt) }
}

// Unified usage colour scheme — used by UsageBar + ThresholdSliderView so the
// whole popover speaks one visual language. 3 buckets only: safe / warn /
// critical. The previous palette also had an "orange" tier that was visually
// indistinguishable from the warn/critical pair next to it.
enum UsagePalette {
    static func color(for percent: Int) -> Color {
        switch percent {
        case ..<60:  return Color(red: 0.13, green: 0.77, blue: 0.37)   // green #22C55E
        case ..<85:  return Color(red: 0.92, green: 0.70, blue: 0.03)   // amber #EAB308
        default:     return Color(red: 0.94, green: 0.27, blue: 0.27)   // red #EF4444
        }
    }
}

/// Skeleton placeholder shown while usage is still loading.
struct SkeletonBar: View {
    let label: String
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.5))
                .frame(width: 18, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(LinearGradient(
                        colors: [
                            Color.primary.opacity(0.06),
                            Color.primary.opacity(0.14),
                            Color.primary.opacity(0.06)
                        ],
                        startPoint: .init(x: phase - 0.3, y: 0.5),
                        endPoint: .init(x: phase + 0.3, y: 0.5)
                    ))
                    .frame(width: geo.size.width)
            }
            .frame(height: 5)
            Text("—").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                .frame(width: 38, alignment: .trailing)
            Text("—").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                .frame(width: 56, alignment: .trailing)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1.3
            }
        }
    }
}
