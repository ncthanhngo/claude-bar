import SwiftUI

// Reusable Today / This week / This month KPI strip. Lives outside
// TokenStatsSection so Dashboard can show the same numbers without dragging
// the chart along.
struct TokenSummaryStripView: View {
    let stats: UsageStatsDTO

    private var waveColor: Color {
        Color(red: 0.18, green: 0.80, blue: 0.55)
    }

    var body: some View {
        HStack(spacing: 8) {
            card(title: "Today",      bucket: stats.today,     tint: waveColor)
            card(title: "This week",  bucket: stats.thisWeek,  tint: waveColor.opacity(0.78))
            card(title: "This month", bucket: stats.thisMonth, tint: waveColor.opacity(0.55))
        }
    }

    private func card(title: String, bucket: UsageBucketDTO, tint: Color) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
            // Cost-equivalent (billable weight) is the hero — it answers "how
            // much did I actually use", whereas the raw total is dominated by
            // cheap cache reads. Raw total drops to a reference subline.
            // Dollar estimates were dropped — subscription accounts don't pay
            // per token, so the USD figure was misleading.
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                // Hero = cost-equivalent. Fall back to raw total only when an
                // older backend doesn't emit it (reports 0).
                Text(TokenFormatters.compact(
                    bucket.costEquivalentTokens > 0
                        ? bucket.costEquivalentTokens
                        : bucket.totalTokens))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                // Raw total — all tokens processed, for reference.
                if bucket.costEquivalentTokens > 0 {
                    Text("\(TokenFormatters.compact(bucket.totalTokens)) total")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text("\(bucket.requests) req")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .help("\(bucket.requests) req · in \(TokenFormatters.compact(bucket.inputTokens)) · out \(TokenFormatters.compact(bucket.outputTokens)) · cache_w \(TokenFormatters.compact(bucket.cacheCreationTokens)) · cache_r \(TokenFormatters.compact(bucket.cacheReadTokens)) · cost-eq ≈\(TokenFormatters.compact(bucket.costEquivalentTokens)) (input-equiv, out 5× · cache_w 1.25× · cache_r 0.1×)")
    }
}

// Shared formatter so TokenStatsSection (chart axis) and TokenSummaryStripView
// (KPI cards) speak the same compact-number language.
enum TokenFormatters {
    static func compact(_ n: Int64) -> String {
        let abs = n < 0 ? -n : n
        switch abs {
        case 0..<1_000:                  return "\(n)"
        case 1_000..<1_000_000:          return trimZero(Double(n) / 1_000) + "K"
        case 1_000_000..<1_000_000_000:  return trimZero(Double(n) / 1_000_000) + "M"
        default:                         return trimZero(Double(n) / 1_000_000_000) + "B"
        }
    }

    private static func trimZero(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
