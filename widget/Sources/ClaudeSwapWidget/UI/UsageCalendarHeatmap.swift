import SwiftUI

// GitHub-style contribution heatmap for daily token usage plus three summary
// cards (Active days / Peak day / Streak). Renders the last ~26 weeks of the
// `daily` series as a Mon–Sun × week grid where each cell's tint scales with
// that day's cost-equivalent tokens. Selectable alongside the Wave area chart
// from TokenStatsSection's style switcher.
struct UsageCalendarHeatmap: View {
    let daily: [TimedBucketDTO]

    // Mint accent for the KPI summary cards' left rail.
    private static let accent = Color(red: 0.18, green: 0.80, blue: 0.55)

    // Follows the popover window appearance so the empty-cell shade matches
    // light vs dark, like GitHub's own contribution graph.
    @Environment(\.colorScheme) private var scheme

    private var model: HeatmapModel { HeatmapModel(daily: daily) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            grid
            legend
            summaryCards
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Less → More key mirroring GitHub's five-step scale.
    private var legend: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("Less").font(.system(size: 8)).foregroundColor(.secondary)
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(i == 0 ? emptyColor : greenLevel(i))
                    .frame(width: 9, height: 9)
            }
            Text("More").font(.system(size: 8)).foregroundColor(.secondary)
        }
    }

    // MARK: Grid

    private var grid: some View {
        let m = model
        return HStack(alignment: .top, spacing: 4) {
            // Weekday rail — label only Mon/Wed/Fri/Sun to match the reference
            // and keep the rail narrow.
            VStack(alignment: .trailing, spacing: HeatmapMetrics.cellGap) {
                ForEach(0..<7, id: \.self) { row in
                    Text(Self.weekdayLabel(row))
                        .font(.system(size: 7))
                        .foregroundColor(.secondary)
                        .frame(height: HeatmapMetrics.cell, alignment: .center)
                }
            }
            .frame(width: 20, alignment: .trailing)

            // Week columns, oldest → newest left → right.
            GeometryReader { geo in
                let cols = m.weeks.count
                // Shrink the cell if the popover is narrower than the natural
                // grid so all weeks stay visible without horizontal scroll.
                let natural = HeatmapMetrics.cell
                let avail = geo.size.width
                let per = min(natural,
                              (avail - CGFloat(cols - 1) * HeatmapMetrics.cellGap) / CGFloat(max(cols, 1)))
                let cell = max(4, per)
                HStack(spacing: HeatmapMetrics.cellGap) {
                    ForEach(Array(m.weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: HeatmapMetrics.cellGap) {
                            ForEach(0..<7, id: \.self) { row in
                                cellView(week[row], side: cell)
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
            }
            .frame(height: HeatmapMetrics.cell * 7 + HeatmapMetrics.cellGap * 6)
        }
    }

    @ViewBuilder
    private func cellView(_ day: HeatmapDay?, side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill(for: day))
            .frame(width: side, height: side)
            .help(day.map(Self.tooltip) ?? "")
    }

    // GitHub-style intensity: an empty shade for no-activity days, then four
    // green steps scaled against the window's peak.
    private func fill(for day: HeatmapDay?) -> Color {
        guard let day, day.value > 0 else { return emptyColor }
        let ratio = model.peakValue > 0 ? Double(day.value) / Double(model.peakValue) : 0
        let level: Int
        switch ratio {
        case ..<0.25: level = 1
        case ..<0.50: level = 2
        case ..<0.75: level = 3
        default:      level = 4
        }
        return greenLevel(level)
    }

    // GitHub's contribution palette, light + dark variants (#ebedf0…#216e39
    // light, #161b22…#39d353 dark).
    private var emptyColor: Color {
        scheme == .dark
            ? Color(red: 0.086, green: 0.106, blue: 0.133)
            : Color(red: 0.922, green: 0.929, blue: 0.941)
    }

    private func greenLevel(_ l: Int) -> Color {
        if scheme == .dark {
            switch l {
            case 1:  return Color(red: 0.055, green: 0.267, blue: 0.161)
            case 2:  return Color(red: 0.0,   green: 0.427, blue: 0.196)
            case 3:  return Color(red: 0.149, green: 0.651, blue: 0.255)
            default: return Color(red: 0.224, green: 0.827, blue: 0.325)
            }
        } else {
            switch l {
            case 1:  return Color(red: 0.608, green: 0.914, blue: 0.659)
            case 2:  return Color(red: 0.251, green: 0.769, blue: 0.388)
            case 3:  return Color(red: 0.188, green: 0.631, blue: 0.306)
            default: return Color(red: 0.129, green: 0.431, blue: 0.224)
            }
        }
    }

    // MARK: Summary cards

    private var summaryCards: some View {
        let m = model
        return HStack(spacing: 8) {
            statCard(title: "Active days", value: "\(m.activeDays)", sub: "of \(daily.count)")
            statCard(title: "Peak day",
                     value: m.peakValue > 0 ? TokenFormatters.compact(m.peakValue) : "—",
                     sub: m.peakDateLabel)
            statCard(title: "Streak", value: "\(m.longestStreak)d", sub: "longest")
        }
    }

    private func statCard(title: String, value: String, sub: String) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Self.accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(sub)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: Labels

    private static func weekdayLabel(_ row: Int) -> String {
        // row 0 = Monday … row 6 = Sunday.
        switch row {
        case 0: return "Mon"
        case 2: return "Wed"
        case 4: return "Fri"
        case 6: return "Sun"
        default: return ""
        }
    }

    private static func tooltip(_ day: HeatmapDay) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d"
        return "\(f.string(from: day.date)): \(TokenFormatters.compact(day.value)) cost-eq"
    }
}

private enum HeatmapMetrics {
    static let cell: CGFloat = 10
    static let cellGap: CGFloat = 3
}

// One day cell in the grid.
private struct HeatmapDay {
    let date: Date
    let value: Int64 // cost-equivalent tokens (falls back to raw total)
}

// Folds the daily series into a Mon–Sun × week matrix and derives the summary
// stats. Weeks are Monday-anchored; leading/trailing cells outside the data
// window are nil (rendered as empty cells).
private struct HeatmapModel {
    let weeks: [[HeatmapDay?]] // each inner array is length 7, row 0 = Monday
    let activeDays: Int
    let peakValue: Int64
    let peakDate: Date?
    let longestStreak: Int

    init(daily: [TimedBucketDTO]) {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday

        func value(_ b: UsageBucketDTO) -> Int64 {
            b.costEquivalentTokens > 0 ? b.costEquivalentTokens : b.totalTokens
        }

        // Map each bucket to (mondayOfWeek, weekdayRow).
        guard let first = daily.first, let last = daily.last else {
            weeks = []; activeDays = 0; peakValue = 0; peakDate = nil; longestStreak = 0
            return
        }
        let firstMonday = HeatmapModel.mondayStart(of: first.start, cal: cal)
        let lastMonday = HeatmapModel.mondayStart(of: last.start, cal: cal)
        let weekCount = max(1, (cal.dateComponents([.day], from: firstMonday, to: lastMonday).day ?? 0) / 7 + 1)

        var matrix: [[HeatmapDay?]] = Array(
            repeating: Array(repeating: nil, count: 7), count: weekCount)

        var active = 0
        var peak: Int64 = 0
        var peakAt: Date?
        var streak = 0
        var run = 0

        for b in daily {
            let v = value(b.bucket)
            let dayMonday = HeatmapModel.mondayStart(of: b.start, cal: cal)
            let col = (cal.dateComponents([.day], from: firstMonday, to: dayMonday).day ?? 0) / 7
            let row = HeatmapModel.mondayIndex(of: b.start, cal: cal)
            if col >= 0 && col < weekCount {
                matrix[col][row] = HeatmapDay(date: b.start, value: v)
            }
            if v > 0 {
                active += 1
                run += 1
                streak = max(streak, run)
                if v > peak { peak = v; peakAt = b.start }
            } else {
                run = 0
            }
        }

        weeks = matrix
        activeDays = active
        peakValue = peak
        peakDate = peakAt
        longestStreak = streak
    }

    var peakDateLabel: String {
        guard let peakDate else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: peakDate)
    }

    // Monday 00:00 of the week containing `date`.
    private static func mondayStart(of date: Date, cal: Calendar) -> Date {
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    // 0 = Monday … 6 = Sunday.
    private static func mondayIndex(of date: Date, cal: Calendar) -> Int {
        let wd = cal.component(.weekday, from: date) // 1 = Sun … 7 = Sat
        return (wd + 5) % 7
    }
}
