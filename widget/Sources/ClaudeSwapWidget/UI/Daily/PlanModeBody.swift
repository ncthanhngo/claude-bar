import SwiftUI

/// Editorial planner body. Adds a top MCP source bar then a 2-column grid
/// of MCP-derived cards: left = hero + action list + Slack mentions; right
/// = Calendar timeline, ClickUp due, Email follow-ups.
///
/// Backed by the existing BriefingDTO from BriefingCoordinator; phase 10
/// regroups + restyles the data the briefing pipeline already pulls from
/// MCP connectors (Google Calendar / Gmail / Slack / ClickUp).
struct PlanModeBody: View {
    @EnvironmentObject private var coord: BriefingCoordinator
    let palette: BriefingPalette

    var body: some View {
        VStack(spacing: 0) {
            if let b = coord.briefing {
                PlanMCPSourceBar(
                    sourcesHealth: b.sourcesHealth,
                    lastUpdatedLabel: lastUpdatedShort(b.generatedAt),
                    palette: palette
                )
                ScrollView(.vertical, showsIndicators: false) {
                    cardsGrid(b)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                }
                BriefingFooterTickerView(palette: palette, sourcesCount: sourcesCount)
            } else {
                BriefingSkeleton(palette: palette).frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func cardsGrid(_ b: BriefingDTO) -> some View {
        // Fixed-width right column (420pt) prevents the hero's long serif
        // title from squeezing it. Left column flexes with the window —
        // looks balanced at the 1280pt + Daily inset where most users sit.
        HStack(alignment: .top, spacing: 24) {
            leftColumn(b)
                .frame(maxWidth: .infinity, alignment: .leading)
            rightColumn(b)
                .frame(width: 420, alignment: .leading)
        }
    }

    @ViewBuilder private func leftColumn(_ b: BriefingDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HeroHeaderView(hero: b.hero, palette: palette)
            VStack(spacing: 0) {
                ForEach(b.actions.prefix(4)) { action in
                    ActionRowView(action: action, palette: palette) {
                        Task { await coord.toggleAction(id: action.id, done: !action.done) }
                    }
                }
            }
            PlanActionsBySourceCard(
                variant: .slack,
                actions: actions(from: b, source: .slack),
                palette: palette
            )
        }
    }

    @ViewBuilder private func rightColumn(_ b: BriefingDTO) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PlanCalendarCard(events: b.calendar, palette: palette)
            PlanReadingCard(palette: palette)
            PlanActionsBySourceCard(
                variant: .clickup,
                actions: actions(from: b, source: .task),
                palette: palette
            )
            PlanActionsBySourceCard(
                variant: .email,
                actions: actions(from: b, source: .email),
                palette: palette
            )
        }
    }

    private func actions(from b: BriefingDTO, source: ActionDTO.Source) -> [ActionDTO] {
        b.actions.filter { $0.source == source }
    }

    private var sourcesCount: Int {
        guard let b = coord.briefing else { return 4 }
        return b.sourcesHealth.values.filter { $0 == "ok" }.count
    }

    private func lastUpdatedShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// Minimal loading skeleton while the briefing is fetching. Re-housed here
/// so `BriefingView` can stay a pure composition root.
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
