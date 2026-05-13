import SwiftUI
import AppKit

/// Top-of-popover hero — biggest visual element. One number, one countdown,
/// optional weekly bar. No technical clutter.
struct HeroCard: View {
    @ObservedObject var store: UsageStore

    private var snapshot: UsageSnapshot { store.snapshot }
    private var color: Color { UsageColor.forPercent(snapshot.sessionPercent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sessionRow
            sessionBar
            if let week = snapshot.weeklyPercent, let weekReset = snapshot.weeklyResetsAt {
                weeklyRow(week: week, weekReset: weekReset)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Sub-views

    private var sessionRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Session").font(.caption).foregroundStyle(.secondary)
                    if snapshot.isLive {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.20))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                Text("\(Int(snapshot.sessionPercent.rounded()))%")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("Resets in").font(.caption).foregroundStyle(.secondary)
                Text(MenuBarLabel.formatRemaining(snapshot.sessionRemaining))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    private var sessionBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: geo.size.width * min(snapshot.sessionPercent / 100.0, 1.0))
                    .animation(.easeOut(duration: 0.5), value: snapshot.sessionPercent)
            }
        }
        .frame(height: 8)
    }

    private func weeklyRow(week: Double, weekReset: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Weekly").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(week.rounded()))%").font(.caption).monospacedDigit()
                Text("· resets \(weekReset, style: .relative)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(UsageColor.forPercent(week))
                        .frame(width: geo.size.width * min(week / 100.0, 1.0))
                }
            }
            .frame(height: 5)
        }
    }
}
