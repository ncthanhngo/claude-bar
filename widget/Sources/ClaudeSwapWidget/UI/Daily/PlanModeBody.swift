import SwiftUI

/// Editorial planner body — extracted from the original `BriefingView`. Owns
/// the hero + action list (left column) and calendar + minis (right column),
/// plus the footer ticker. Renders only when `DailyMode == .plan`.
struct PlanModeBody: View {
    @EnvironmentObject private var coord: BriefingCoordinator
    let palette: BriefingPalette

    var body: some View {
        VStack(spacing: 16) {
            if let b = coord.briefing {
                mainGrid(b)
            } else {
                BriefingSkeleton(palette: palette).frame(maxHeight: .infinity)
            }
            BriefingFooterTickerView(palette: palette, sourcesCount: sourcesCount)
        }
    }

    @ViewBuilder private func mainGrid(_ briefing: BriefingDTO) -> some View {
        HStack(alignment: .top, spacing: 32) {
            leftColumn(briefing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(2)
            rightColumn(briefing)
                .frame(width: 400, alignment: .leading)
                .layoutPriority(1)
        }
    }

    @ViewBuilder private func leftColumn(_ briefing: BriefingDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HeroHeaderView(hero: briefing.hero, palette: palette)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(briefing.actions) { action in
                        ActionRowView(action: action, palette: palette) {
                            Task { await coord.toggleAction(id: action.id, done: !action.done) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func rightColumn(_ briefing: BriefingDTO) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CalendarTimelineView(events: briefing.calendar, palette: palette)
            MiniNewsCard(palette: palette)
            MiniTelegramCard(palette: palette)
        }
    }

    private var sourcesCount: Int {
        guard let b = coord.briefing else { return 4 }
        return b.sourcesHealth.values.filter { $0 == "ok" }.count
    }
}

/// Minimal loading skeleton while the briefing is fetching. Re-housed here so
/// `BriefingView` can shrink to a pure composition root.
struct BriefingSkeleton: View {
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.line)
                    .frame(height: 28)
                    .opacity(0.6)
            }
            Spacer()
        }
        .padding(.top, 24)
    }
}
