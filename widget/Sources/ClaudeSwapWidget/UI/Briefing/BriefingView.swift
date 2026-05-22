import SwiftUI

/// Root Daily Briefing view. Two-column landscape layout:
/// left (1.55fr) = hero + action list; right (1fr) = calendar + minis.
struct BriefingView: View {
    @EnvironmentObject private var coord: BriefingCoordinator
    @ObservedObject private var settings = AppSettings.shared

    private var palette: BriefingPalette { settings.widgetTheme.briefingPalette }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()
            VStack(spacing: 16) {
                topBar
                if let b = coord.briefing {
                    mainGrid(b)
                } else {
                    BriefingSkeleton(palette: palette).frame(maxHeight: .infinity)
                }
                BriefingFooterTickerView(palette: palette, sourcesCount: sourcesCount)
            }
            .padding(EdgeInsets(top: 22, leading: 28, bottom: 22, trailing: 28))
        }
        .frame(minWidth: 1280, minHeight: 800)
    }

    @ViewBuilder private var topBar: some View {
        BriefingTopBarView(
            palette: palette,
            dateLabel: dateLabel,
            lastGenerated: lastGeneratedLabel,
            nextRun: nextRunLabel,
            isRunning: coord.isRunning,
            onRun: { Task { await coord.runNow() } },
            onSettings: { NotificationCenter.default.post(name: .openSettings, object: nil) },
            onClose: { coord.close() }
        )
    }

    @ViewBuilder private func mainGrid(_ briefing: BriefingDTO) -> some View {
        HStack(alignment: .top, spacing: 32) {
            leftColumn(briefing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(2)
            rightColumn(briefing)
                .frame(maxWidth: 420, alignment: .leading)
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
            HStack(spacing: 14) {
                MiniNewsCard(palette: palette).frame(maxWidth: .infinity)
                MiniTelegramCard(palette: palette).frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var backgroundLayer: some View {
        ZStack {
            palette.paper
            RadialGradient(
                colors: [palette.rose.opacity(0.08), .clear],
                center: .topLeading, startRadius: 0, endRadius: 700
            )
            RadialGradient(
                colors: [palette.sage.opacity(0.07), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 700
            )
        }
    }

    // MARK: - Labels

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "EEEE · d / M"
        return f.string(from: Date()).capitalized
    }

    private var lastGeneratedLabel: String {
        guard let b = coord.briefing else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "HH:mm 'sáng'"
        return f.string(from: b.generatedAt)
    }

    private var nextRunLabel: String {
        guard let s = coord.schedule, !s.cronExpr.isEmpty else { return "—" }
        return "08:33 mai"
    }

    private var sourcesCount: Int {
        guard let b = coord.briefing else { return 4 }
        return b.sourcesHealth.values.filter { $0 == "ok" }.count
    }
}

/// Minimal loading skeleton while briefing is fetching.
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
