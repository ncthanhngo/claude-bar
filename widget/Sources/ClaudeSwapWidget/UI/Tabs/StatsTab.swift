import SwiftUI

// Token-usage analytics tab. Hosts the chart (Hour/Day/Month × Tokens/USD)
// plus the Today / Week / Month KPI strip — the same TokenStatsSection the
// old Claude tab used to embed alongside everything else. No account list,
// no auto-swap controls; pure read-only analytics.
struct StatsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TokenStatsSection()
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
