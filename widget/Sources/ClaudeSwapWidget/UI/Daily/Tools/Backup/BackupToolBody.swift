import SwiftUI

/// The "Sao lưu" top-level tool. Two panes behind a small sub-switcher:
///   • Hồ sơ — the existing backup-profile editor (BackupRestoreView).
///   • Trợ lý — an AI assistant (the active Claude account) that can run
///     commands on a tracked SSH host to install / configure things.
/// Both panes stay alive (opacity) so switching never reloads their state.
struct BackupToolBody: View {
    @ObservedObject var backup: BackupRestoreStore
    @ObservedObject var agent: ServerAgentStore
    let palette: BriefingPalette

    enum Pane: String, CaseIterable, Identifiable {
        case profiles, assistant
        var id: String { rawValue }
        var label: String { self == .profiles ? "Hồ sơ" : "Trợ lý máy chủ" }
        var icon: String { self == .profiles ? "externaldrive.badge.timemachine" : "sparkles" }
    }

    @State private var pane: Pane = .profiles

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            subSwitcher
            ZStack {
                BackupRestoreView(store: backup, palette: palette)
                    .opacity(pane == .profiles ? 1 : 0)
                    .allowsHitTesting(pane == .profiles)
                ServerAgentView(store: agent, palette: palette)
                    .opacity(pane == .assistant ? 1 : 0)
                    .allowsHitTesting(pane == .assistant)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(Pane.allCases) { p in
                let active = pane == p
                Button { pane = p } label: {
                    Label(p.label, systemImage: p.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(active ? palette.ink : palette.ink3)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(active ? palette.ink.opacity(0.08) : .clear))
                        .overlay(Capsule().stroke(active ? palette.line2 : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
