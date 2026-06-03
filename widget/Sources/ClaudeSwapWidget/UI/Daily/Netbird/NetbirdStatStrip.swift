import SwiftUI

/// Slim inline summary — server · dev · online · pending as compact pills.
/// Replaces the old four-card strip to keep the panel short.
struct NetbirdStatStrip: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette

    var body: some View {
        HStack(spacing: 8) {
            pill("\(coord.servers.count)", "server", palette.moss)
            pill("\(coord.devs.count)", "dev", palette.gold)
            pill("\(coord.onlineCount)", "online", palette.sage)
            pill("\(coord.pending.count)", "chờ duyệt",
                 coord.pending.isEmpty ? palette.ink3 : palette.coral)
            Spacer(minLength: 0)
        }
    }

    private func pill(_ n: String, _ k: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(n).font(.system(size: 14, weight: .bold)).foregroundColor(palette.ink)
            Text(k).font(.system(size: 12)).foregroundColor(palette.ink2)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(palette.raisedSurface))
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }
}
