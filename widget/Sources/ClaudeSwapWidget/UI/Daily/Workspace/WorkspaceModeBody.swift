import SwiftUI

/// Live "Action Inbox" body for the Daily Workspace tab. Polls the rule-derived
/// `csw workspace feed` and renders signals grouped by urgency. Read-only +
/// deep-link in this phase; AI draft + execute land in later phases.
struct WorkspaceModeBody: View {
    let palette: BriefingPalette
    @StateObject private var coord = WorkspaceCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            header
            if let feed = coord.feed {
                if feed.signals.isEmpty {
                    emptyState
                } else {
                    feedScroll(feed)
                }
            } else {
                BriefingSkeleton(palette: palette).frame(maxHeight: .infinity)
            }
        }
        .onAppear { coord.start() }
        .onDisappear { coord.stop() }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            liveDot
            Text("Workspace")
                .font(.system(size: 22, weight: .regular, design: .serif).italic())
                .foregroundColor(palette.ink)
            Text(updatedLabel)
                .font(.system(size: 11.5))
                .foregroundColor(palette.ink3)
            if !coord.newSignalIDs.isEmpty {
                Text("\(coord.newSignalIDs.count) mới")
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(palette.coral))
                    .foregroundColor(.white)
            }
            Spacer()
            Button { Task { await coord.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.ink2)
                    .rotationEffect(.degrees(coord.isRefreshing ? 360 : 0))
                    .animation(coord.isRefreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: coord.isRefreshing)
            }
            .buttonStyle(.plain)
            .help("Làm mới feed")
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private var liveDot: some View {
        Circle()
            .fill(coord.lastError == nil ? palette.sage : palette.coral)
            .frame(width: 8, height: 8)
    }

    // MARK: feed

    @ViewBuilder private func feedScroll(_ feed: WorkspaceFeedDTO) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                section("Cần xử lý ngay", feed.signals.filter { $0.urgency == .urgent })
                section("Sắp tới", feed.signals.filter { $0.urgency == .soon })
                section("Khác", feed.signals.filter { $0.urgency == .normal })
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .onAppear { coord.acknowledgeNew() }
    }

    @ViewBuilder private func section(_ title: String, _ signals: [WorkspaceSignalDTO]) -> some View {
        if !signals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(palette.ink3)
                ForEach(signals) { s in
                    WorkspaceSignalCard(signal: s, isNew: coord.newSignalIDs.contains(s.id), palette: palette)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(palette.sage)
            Text("Không có việc cần xử lý")
                .font(.system(size: 15, weight: .medium, design: .serif))
                .foregroundColor(palette.ink2)
            Text("Inbox sạch — feed tự cập nhật vài phút một lần.")
                .font(.system(size: 12))
                .foregroundColor(palette.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var updatedLabel: String {
        guard let f = coord.feed else { return "đang tải…" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "cập nhật " + fmt.string(from: f.generatedAt)
    }
}
