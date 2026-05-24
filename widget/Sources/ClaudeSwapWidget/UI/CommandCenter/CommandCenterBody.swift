import SwiftUI

/// Command Center body for the Daily tab. Layout (matches the v2 mockup):
///
///   ┌───────────────────────────────────────────────────────────┐
///   │ source bar (MCP health) + CaptureBox                      │
///   ├───────────────────────────────────────────────┬───────────┤
///   │ Focus statement                               │           │
///   │ Commitments grouped by action verb            │ Session   │
///   │ Servers rail                                  │ panel     │
///   │ Watch band                                    │           │
///   └───────────────────────────────────────────────┴───────────┘
///
/// Reuses BriefingDTO from the existing briefing pipeline; no new backend
/// data plumbing required.
struct CommandCenterBody: View {
    @EnvironmentObject private var coord: BriefingCoordinator
    let palette: BriefingPalette

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    leftColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SessionPanel()
                        .frame(width: 360)
                        .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        VStack(spacing: 6) {
            if let b = coord.briefing {
                PlanMCPSourceBar(
                    sourcesHealth: b.sourcesHealth,
                    lastUpdatedLabel: lastUpdatedShort(b.generatedAt),
                    palette: palette
                )
            }
            CaptureBox()
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
        }
    }

    // MARK: - Left column

    @ViewBuilder
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let b = coord.briefing {
                focusCard(b)
                commitmentsByVerb(b)
                ServersRail()
                    .padding(.top, 4)
                watchBand(b)
            } else {
                BriefingSkeleton(palette: palette).frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Focus card

    private func focusCard(_ b: BriefingDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(b.hero.eyebrow.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(.secondary)
            Text(b.hero.title)
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundColor(.primary)
                .lineLimit(2)
            if !b.hero.focusBody.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "bolt.fill").foregroundColor(.orange).font(.system(size: 10))
                    Text(b.hero.focusBody)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08))
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        )
    }

    // MARK: - Commitments by verb

    private func commitmentsByVerb(_ b: BriefingDTO) -> some View {
        let groups = groupByVerb(b.actions)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(VerbGroup.allCases, id: \.self) { verb in
                if let items = groups[verb], !items.isEmpty {
                    verbSection(verb, items: items)
                }
            }
        }
    }

    private func verbSection(_ verb: VerbGroup, items: [ActionDTO]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: verb.icon).foregroundColor(verb.tone).font(.system(size: 10))
                Text(verb.label.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(verb.tone)
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            ForEach(items) { action in
                ActionRowView(action: action, palette: palette) {
                    Task { await coord.toggleAction(id: action.id, done: !action.done) }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(verb.tone.opacity(0.05))
        )
    }

    // MARK: - Watch band

    private func watchBand(_ b: BriefingDTO) -> some View {
        let watchItems = b.actions.filter { $0.priority == .normal && !$0.done }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "binoculars").foregroundColor(.secondary).font(.system(size: 10))
                Text("Watch").font(.system(size: 10, weight: .heavy)).foregroundColor(.secondary)
                Spacer()
                Text("\(watchItems.count) item").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            }
            if watchItems.isEmpty {
                Text("Không có việc đang theo dõi.").font(.caption2).foregroundColor(.secondary)
            } else {
                ForEach(watchItems.prefix(4)) { a in
                    Text("• \(a.title)").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
                if watchItems.count > 4 {
                    Text("+\(watchItems.count - 4) more").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
    }

    // MARK: - Helpers

    private func lastUpdatedShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// Bucket actions by verb. Conservative heuristic on title keywords +
    /// priority — good enough until backend Action DTO gains a `verb` field
    /// (Phase 5 plan F14: needs DTO additions).
    private func groupByVerb(_ actions: [ActionDTO]) -> [VerbGroup: [ActionDTO]] {
        var out: [VerbGroup: [ActionDTO]] = [:]
        for a in actions where !a.done {
            out[verbOf(a), default: []].append(a)
        }
        return out
    }

    private func verbOf(_ a: ActionDTO) -> VerbGroup {
        let t = a.title.lowercased()
        if a.priority == .urgent { return .respond }
        if t.contains("ship") || t.contains("merge") || t.contains("release") || t.contains("deploy") {
            return .ship
        }
        if t.contains("reply") || t.contains("respond") || t.contains("answer") || a.source == .email || a.source == .slack {
            return .respond
        }
        if t.contains("review") || t.contains("decide") || t.contains("approve") || a.source == .task {
            return .decide
        }
        return .decide
    }
}

enum VerbGroup: CaseIterable, Hashable {
    case ship
    case respond
    case decide

    var label: String {
        switch self {
        case .ship: return "Must ship"
        case .respond: return "Must respond"
        case .decide: return "Must decide"
        }
    }

    var icon: String {
        switch self {
        case .ship: return "shippingbox"
        case .respond: return "bubble.left.and.bubble.right"
        case .decide: return "checklist"
        }
    }

    var tone: Color {
        switch self {
        case .ship: return .blue
        case .respond: return .orange
        case .decide: return .green
        }
    }
}
