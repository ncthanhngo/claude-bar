import SwiftUI
import Charts

// Month-granularity token view: a year-spanning sparkline of cost-equivalent
// tokens on top (with the running yearly total), then one scrollable row per
// month sorted newest-first — current month at the top. Each row carries a
// proportional mini-bar, the compact token figure, and a month-over-month
// delta chip so the fluctuation reads at a glance.
//
// Data = `UsageStatsDTO.monthly`, a rolling 12-month window (oldest → newest,
// ending with the current month). There is no calendar-year navigation: the
// backend prunes JSONL older than 13 months, so past years aren't available —
// hence the range label instead of a year picker.
struct MonthlyBreakdownChart: View {
    let monthly: [TimedBucketDTO]

    // Mint accent shared with the Wave chart / heatmap so the styles read as
    // one family; coral marks a month-over-month increase (more spend = worth
    // a heads-up), mint marks a decrease.
    private static let accent = Color(red: 0.18, green: 0.80, blue: 0.55)
    private static let spike = Color(red: 1.0, green: 0.42, blue: 0.42)

    private var model: MonthlyModel { MonthlyModel(monthly: monthly) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            sparkCard
            rows
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.rangeLabel)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
            Spacer(minLength: 8)
            Text("cost-eq · theo tháng")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: Sparkline card

    private var sparkCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.hasData ? TokenFormatters.compact(model.total) : "—")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                Text("tổng cả năm · cost-eq")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }
            sparkline
                .frame(height: 52)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var sparkline: some View {
        Chart(model.points) { p in
            AreaMark(
                x: .value("Month", p.start, unit: .month),
                y: .value("cost-eq", Double(p.value))
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(
                LinearGradient(
                    colors: [Self.accent.opacity(0.38), Self.accent.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Month", p.start, unit: .month),
                y: .value("cost-eq", Double(p.value))
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(Self.accent)
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            // Emphasise the latest month so the eye lands on "now".
            if p.isLast {
                PointMark(
                    x: .value("Month", p.start, unit: .month),
                    y: .value("cost-eq", Double(p.value))
                )
                .symbolSize(38)
                .foregroundStyle(Color(red: 0.30, green: 1.0, blue: 0.69))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .overlay {
            if !model.hasData {
                Text("Chưa có dữ liệu tháng nào.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Rows (newest first)

    private var rows: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(model.rows) { row in
                    monthRow(row)
                }
            }
        }
        .frame(maxHeight: 210)
    }

    private func monthRow(_ row: MonthRow) -> some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(.system(size: 11, weight: row.isCurrent ? .bold : .regular, design: .monospaced))
                .foregroundColor(row.isCurrent ? Self.accent : .secondary)
                .frame(width: 34, alignment: .leading)

            miniBar(fraction: row.fraction, current: row.isCurrent, empty: row.isEmpty)
                .frame(height: 6)

            Text(row.isEmpty ? "—" : TokenFormatters.compact(row.value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(row.isEmpty ? .secondary : .primary)
                .frame(width: 54, alignment: .trailing)

            deltaChip(row.delta)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .help(row.tooltip)
    }

    private func miniBar(fraction: Double, current: Bool, empty: Bool) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                if !empty {
                    Capsule()
                        .fill(fillStyle(current: current))
                        .frame(width: max(4, g.size.width * fraction))
                }
            }
        }
    }

    private func fillStyle(current: Bool) -> AnyShapeStyle {
        if current {
            // Gradient = the month is still accumulating (in progress).
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Self.accent, Self.accent.opacity(0.45)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
        }
        return AnyShapeStyle(Self.accent)
    }

    @ViewBuilder
    private func deltaChip(_ delta: Double?) -> some View {
        if let d = delta {
            let up = d > 0
            let pct = "\(up ? "▲" : "▼") \(Int(abs(d).rounded()))%"
            Text(pct)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(up ? Self.spike : Self.accent)
                .padding(.vertical, 1.5)
                .padding(.horizontal, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill((up ? Self.spike : Self.accent).opacity(0.13))
                )
        } else {
            Text("—")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.vertical, 1.5)
                .padding(.horizontal, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
        }
    }
}

// MARK: - Model

private struct SparkPoint: Identifiable {
    let start: Date
    let value: Int64
    let isLast: Bool
    var id: Date { start }
}

private struct MonthRow: Identifiable {
    let start: Date
    let label: String
    let value: Int64
    let fraction: Double
    let delta: Double? // month-over-month %, nil when no prior month
    let isCurrent: Bool
    let isEmpty: Bool
    let tooltip: String
    var id: Date { start }
}

// Folds the rolling 12-month series into the sparkline points (chronological)
// and the row list (newest-first) with per-month MoM deltas.
private struct MonthlyModel {
    let points: [SparkPoint]
    let rows: [MonthRow]
    let total: Int64
    let hasData: Bool
    let rangeLabel: String

    init(monthly: [TimedBucketDTO]) {
        func value(_ b: UsageBucketDTO) -> Int64 {
            b.costEquivalentTokens > 0 ? b.costEquivalentTokens : b.totalTokens
        }

        let values = monthly.map { value($0.bucket) }
        let peak = values.max() ?? 0
        let sum = values.reduce(0, +)
        let lastIdx = monthly.count - 1

        let shortFmt = DateFormatter()
        shortFmt.locale = Locale(identifier: "en_US_POSIX")
        shortFmt.dateFormat = "MMM"

        let tipFmt = DateFormatter()
        tipFmt.locale = Locale(identifier: "en_US_POSIX")
        tipFmt.dateFormat = "MMM yyyy"

        points = monthly.enumerated().map { i, b in
            SparkPoint(start: b.start, value: values[i], isLast: i == lastIdx)
        }

        // MoM delta vs the previous chronological month (0 → nil to avoid /0).
        func delta(_ i: Int) -> Double? {
            guard i > 0 else { return nil }
            let prev = values[i - 1]
            guard prev > 0 else { return nil }
            return Double(values[i] - prev) / Double(prev) * 100
        }

        // Newest first: current month on top.
        rows = monthly.enumerated().reversed().map { i, b in
            let v = values[i]
            let empty = v == 0
            let d = delta(i)
            let current = i == lastIdx
            let frac = peak > 0 ? Double(v) / Double(peak) : 0
            var tip = "\(tipFmt.string(from: b.start)): "
            tip += empty ? "chưa có" : TokenFormatters.compact(v) + " cost-eq"
            if current && !empty { tip += " · đang chạy" }
            if let d { tip += String(format: " · %@%.0f%% so tháng trước", d > 0 ? "▲" : "▼", abs(d)) }
            return MonthRow(
                start: b.start,
                label: shortFmt.string(from: b.start),
                value: v,
                fraction: frac,
                delta: d,
                isCurrent: current,
                isEmpty: empty,
                tooltip: tip
            )
        }

        total = sum
        hasData = sum > 0

        if let first = monthly.first?.start, let last = monthly.last?.start {
            let rf = DateFormatter()
            rf.locale = Locale(identifier: "en_US_POSIX")
            rf.dateFormat = "MMM ''yy"
            rangeLabel = "\(rf.string(from: first)) – \(rf.string(from: last))"
        } else {
            rangeLabel = "12 tháng"
        }
    }
}
