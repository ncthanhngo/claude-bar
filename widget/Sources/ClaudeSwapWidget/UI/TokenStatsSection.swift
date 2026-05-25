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
    @State private var metric: ChartMetric = .tokens
    @State private var showingPricingDetails = false

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

    enum ChartMetric: String, CaseIterable, Identifiable {
        case tokens, cost
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tokens: return "Tokens"
            case .cost:   return "USD"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stats = store.tokenStats {
                pickerBar
                if showingPricingDetails && metric == .cost && !stats.pricing.isEmpty {
                    PricingTablePopover(
                        rows: stats.pricing,
                        reference: stats.pricingReference
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                UsageChart(stats: stats, granularity: granularity, metric: metric)
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
        HStack(spacing: 10) {
            Picker("", selection: $granularity) {
                ForEach(ChartGranularity.allCases) { g in
                    Text(g.label).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .pointingHandCursor()

            Picker("", selection: $metric) {
                ForEach(ChartMetric.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 140)
            .pointingHandCursor()

            if metric == .cost, let stats = store.tokenStats, !stats.pricing.isEmpty {
                detailsButton(stats: stats)
            }

            Spacer(minLength: 0)
        }
    }

    // Sits next to the USD segment. Only appears once cost is selected. Tap
    // toggles the pricing-rate table inline below the picker — inline rather
    // than `.popover` because MenuBarExtra(.window) clips child popovers to
    // its window bounds.
    private func detailsButton(stats: UsageStatsDTO) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showingPricingDetails.toggle()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: showingPricingDetails ? "chevron.up.circle.fill" : "info.circle")
                    .font(.system(size: 10, weight: .medium))
                Text(showingPricingDetails ? "Hide" : "Details")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(showingPricingDetails ? 0.18 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("How USD is estimated")
    }
}

private struct UsageChart: View {
    let stats: UsageStatsDTO
    let granularity: TokenStatsSection.ChartGranularity
    let metric: TokenStatsSection.ChartMetric

    private var series: [TimedBucketDTO] {
        switch granularity {
        case .hour:  return stats.hourly
        case .day:   return stats.daily
        case .month: return stats.monthly
        }
    }

    // Y value per bucket — switches between raw compute tokens and dollar cost
    // depending on the picker. Bars stay sized relative to the series so the
    // axes are always meaningful even when totals are tiny.
    private func yValue(_ b: UsageBucketDTO) -> Double {
        switch metric {
        case .tokens: return Double(b.totalTokens)
        case .cost:   return b.estimatedCostUsd
        }
    }

    private var yAxisLabel: String {
        switch metric {
        case .tokens: return "Tokens"
        case .cost:   return "USD"
        }
    }

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
        // Chart was a fixed 96pt strip. Letting it grow upward absorbs the
        // slack space the parent VStack now hands down when the Claude tab
        // has only 1–2 accounts; capped at 260pt so a sparse popover doesn't
        // turn into a single gigantic wave.
        .frame(minHeight: 96, maxHeight: 260)
        .overlay(alignment: .center) {
            if !hasData {
                Text("No usage in this window yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatYAxis(_ v: Double) -> String {
        switch metric {
        case .tokens: return TokenFormatters.compact(Int64(v))
        case .cost:   return TokenFormatters.cost(v)
        }
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

