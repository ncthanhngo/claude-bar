import SwiftUI
import Charts

// Renders the Token usage section of the Claude tab: a granularity picker
// (Hour / Day / Month), a bar chart of the corresponding histogram series,
// then the Today / This week / This month total rows. Source = local
// ~/.claude/projects/**/*.jsonl session logs (covers terminal CLI + IDE
// extensions; no per-account attribution since the JSONL never records the
// OAuth account).
struct TokenStatsSection: View {
    @EnvironmentObject var store: AppStore
    @State private var granularity: ChartGranularity = .day

    enum ChartGranularity: String, CaseIterable, Identifiable {
        case hour, day, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hour:  return "Hour"
            case .day:   return "Day"
            case .month: return "Month"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stats = store.tokenStats {
                pickerBar
                UsageChart(stats: stats, granularity: granularity)
                Divider().opacity(0.3)
                TokenSummaryStripView(stats: stats)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Scanning Claude Code logs…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        // Claim any slack the Claude tab passes down so the inner UsageChart
        // (which now grows up to 260pt) can actually receive that extra
        // height instead of the VStack collapsing to intrinsic size.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var pickerBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $granularity) {
                ForEach(ChartGranularity.allCases) { g in
                    Text(g.label).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
            .pointingHandCursor()

            Spacer(minLength: 0)
        }
    }
}

private struct UsageChart: View {
    let stats: UsageStatsDTO
    let granularity: TokenStatsSection.ChartGranularity

    private var series: [TimedBucketDTO] {
        switch granularity {
        case .hour:  return stats.hourly
        case .day:   return stats.daily
        case .month: return stats.monthly
        }
    }

    // Y value per bucket — raw compute tokens. Bars stay sized relative to the
    // series so the axis is meaningful even when totals are tiny.
    private func yValue(_ b: UsageBucketDTO) -> Double {
        Double(b.totalTokens)
    }

    private let yAxisLabel = "Tokens"

    private var hasData: Bool {
        series.contains { yValue($0.bucket) > 0 }
    }

    var body: some View {
        Chart(series) { slot in
            AreaMark(
                x: .value("Bucket", slot.start, unit: unit),
                y: .value(yAxisLabel, yValue(slot.bucket))
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(waveGradient)

            LineMark(
                x: .value("Bucket", slot.start, unit: unit),
                y: .value(yAxisLabel, yValue(slot.bucket))
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(waveColor.opacity(0.95))
            .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis {
            AxisMarks(values: xAxisValues) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatXAxis(date))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let n = value.as(Double.self) {
                        Text(formatYAxis(n))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        // Chart absorbs whatever vertical slack the popover hands down so the
        // KPI strip below it sits flush against the footer instead of leaving
        // a gap when the account list is short.
        .frame(minHeight: 96, maxHeight: .infinity)
        .overlay(alignment: .center) {
            if !hasData {
                Text("No usage in this window yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatYAxis(_ v: Double) -> String {
        TokenFormatters.compact(Int64(v))
    }

    private var unit: Calendar.Component {
        switch granularity {
        case .hour:  return .hour
        case .day:   return .day
        case .month: return .month
        }
    }

    // X-axis tick density: show ~6 labels regardless of bucket count so the
    // axis stays readable in a 360-wide popover.
    private var xAxisValues: AxisMarkValues {
        switch granularity {
        case .hour:  return .stride(by: .hour, count: 4)
        case .day:   return .stride(by: .day, count: 5)
        case .month: return .stride(by: .month, count: 2)
        }
    }

    private func formatXAxis(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch granularity {
        case .hour:
            formatter.dateFormat = "HH'h'"
            return formatter.string(from: date)
        case .day:
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        case .month:
            formatter.dateFormat = "MMM"
            return formatter.string(from: date)
        }
    }

    private var waveColor: Color {
        Color(red: 0.18, green: 0.80, blue: 0.55)
    }

    // Gradient from full mint at the crest down to a faint wash at the floor —
    // gives the area depth without going full 3D.
    private var waveGradient: LinearGradient {
        LinearGradient(
            colors: [
                waveColor.opacity(0.85),
                waveColor.opacity(0.35),
                waveColor.opacity(0.10),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

