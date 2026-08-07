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
    // Persist the chosen chart style so it survives popover reopen.
    @AppStorage("tokenChartStyle") private var chartStyle: ChartStyle = .wave

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

    // Two mutually-exclusive chart styles the user toggles between. Wave = the
    // original area chart with an Hour/Day/Month granularity; Calendar = the
    // GitHub-style 6-month contribution heatmap.
    enum ChartStyle: String, CaseIterable, Identifiable {
        case wave, calendar
        var id: String { rawValue }
        var label: String { self == .wave ? "Wave" : "Calendar" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stats = store.tokenStats {
                styleBar
                if chartStyle == .wave {
                    // Month granularity gets the richer per-month breakdown
                    // (year-spanning sparkline + newest-first month rows with
                    // MoM deltas); Hour/Day keep the area chart.
                    if granularity == .month {
                        MonthlyBreakdownChart(monthly: stats.monthly)
                    } else {
                        UsageChart(stats: stats, granularity: granularity)
                    }
                } else {
                    UsageCalendarHeatmap(daily: stats.daily)
                }
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

    // Style switcher on top; the Hour/Day/Month granularity only appears in
    // Wave mode (the Calendar heatmap has its own fixed 6-month window).
    private var styleBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $chartStyle) {
                    ForEach(ChartStyle.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
                .pointingHandCursor()

                Spacer(minLength: 0)
            }

            if chartStyle == .wave {
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
    }
}

private struct UsageChart: View {
    let stats: UsageStatsDTO
    let granularity: TokenStatsSection.ChartGranularity

    // Day and Month windows are trimmed to the 7 most-recent buckets so each
    // point gets enough horizontal room to read in the widened popover — a
    // week of days, seven months back. Hour keeps its full 24h span. The
    // backend still emits 30d/12m (KPI cards depend on that); we only narrow
    // what the chart plots.
    private var series: [TimedBucketDTO] {
        switch granularity {
        case .hour:  return stats.hourly
        case .day:   return Array(stats.daily.suffix(7))
        case .month: return Array(stats.monthly.suffix(7))
        }
    }

    // Y value per bucket — cost-equivalent tokens, matching the headline figure
    // on the KPI cards below so the chart and cards read on the same scale
    // instead of the chart showing billions while the cards lead with millions.
    // Falls back to the raw total for older backends that don't emit cost-eq.
    private func yValue(_ b: UsageBucketDTO) -> Double {
        Double(b.costEquivalentTokens > 0 ? b.costEquivalentTokens : b.totalTokens)
    }

    private let yAxisLabel = "Cost-eq"

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
        .frame(minHeight: 150, maxHeight: .infinity)
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

    // X-axis tick density. Hour keeps ~6 labels across 24h; Day and Month now
    // plot only 7 buckets each, so label every one — a full week of dates and
    // seven month names, all readable in the widened popover.
    private var xAxisValues: AxisMarkValues {
        switch granularity {
        case .hour:  return .stride(by: .hour, count: 4)
        case .day:   return .stride(by: .day, count: 1)
        case .month: return .stride(by: .month, count: 1)
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

