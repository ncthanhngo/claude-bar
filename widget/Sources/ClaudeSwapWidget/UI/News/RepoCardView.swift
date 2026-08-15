import SwiftUI

/// One GitHub repo card — port of the mockup's `.card.repo`: gradient
/// `owner/repo` name, VN description, and a footer of language dot + stars +
/// weekly delta. Clicking opens the repo's GitHub URL.
struct RepoCardView: View {
    let repo: RepoCard

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            repoName
            if !repo.descVI.isEmpty {
                Text(repo.descVI)
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0x3f / 255, green: 0x42 / 255, blue: 0x60 / 255))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .background(NewsAuroraStyle.cardBackground())
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { openRepo() }
        .pointingHandCursor()
    }

    /// Splits "owner/repo" so only the repo half gets the gradient text
    /// treatment, matching `.repo .name b { background: linear-gradient… }`.
    private var repoName: some View {
        let parts = repo.fullName.split(separator: "/", maxSplits: 1).map(String.init)
        let owner = parts.first ?? repo.fullName
        let name = parts.count > 1 ? parts[1] : ""
        return (
            Text(parts.count > 1 ? "\(owner)/" : owner)
                .foregroundColor(NewsAuroraStyle.ink)
            + Text(name)
                .foregroundStyle(
                    LinearGradient(colors: [NewsAuroraStyle.violet, NewsAuroraStyle.cyan],
                                   startPoint: .leading, endPoint: .trailing)
                )
        )
        .font(.system(size: 14, weight: .heavy, design: .monospaced))
    }

    private var footer: some View {
        HStack(spacing: 13) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: repo.langColor) ?? NewsAuroraStyle.muted)
                    .frame(width: 9, height: 9)
                Text(repo.language)
            }
            Text("★ \(formattedCount(repo.stars))")
            Text("▲ +\(formattedCount(repo.deltaWeek))")
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(NewsAuroraStyle.muted)
    }

    private func formattedCount(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000)
        }
        return String(n)
    }

    private func openRepo() {
        guard !repo.url.isEmpty, let url = URL(string: repo.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension Color {
    /// Parses a "#rrggbb" hex string (the GitHub language color the backend
    /// forwards). Returns nil for anything malformed so callers can fall
    /// back to a neutral color instead of rendering black.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
