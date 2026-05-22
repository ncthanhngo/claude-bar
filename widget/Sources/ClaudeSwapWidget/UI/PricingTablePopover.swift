import SwiftUI

// Inline pricing-rate table revealed when the user taps "Details" next to
// the USD metric on the Claude tab. Renders the per-model rates the
// estimated-cost column is computed against. Data is driven by
// UsageStatsDTO.pricing (sent from the backend domain.PublishedPricing —
// same array the cost calc uses), so the table never drifts from the chart.
//
// Inline rather than `.popover` because MenuBarExtra(.window) clips child
// popovers to its host window bounds. Uses SwiftUI `Grid` so columns
// auto-align without hard-coded widths — the failure mode that broke the
// previous fixed-pixel layout when the parent shrank.
struct PricingTablePopover: View {
    let rows: [ModelPricingDTO]
    let reference: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            gridTable
            Text(reference)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Cách tính USD")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
            Text("Bảng giá Anthropic · USD / 1.000.000 tokens")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var gridTable: some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Model")
                    .gridColumnAlignment(.leading)
                Text("input")
                Text("output")
                Text("cache write")
                Text("cache read")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(.secondary)
            Divider().opacity(0.4).gridCellColumns(5)
            ForEach(rows.indices, id: \.self) { (idx: Int) in
                let row = rows[idx]
                GridRow {
                    Text(row.family.capitalized)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.primary)
                    rateCell(row.input)
                    rateCell(row.output)
                    rateCell(row.cacheWrite)
                    rateCell(row.cacheRead)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rateCell(_ v: Double) -> some View {
        Text(formatRate(v))
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.primary.opacity(0.88))
    }

    // Drops trailing zeros for whole-dollar rates ("15" not "15.00"), keeps
    // two decimals when meaningful ("0.30", "18.75"). Matches how the table
    // reads naturally in print.
    private func formatRate(_ v: Double) -> String {
        if v == v.rounded() { return String(format: "%.0f", v) }
        if (v * 10).rounded() == v * 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}
