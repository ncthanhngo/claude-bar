import SwiftUI
import AppKit

/// "Tin đáng đọc" card — pulls headlines from the user-configured RSS
/// feeds (Settings → Briefing → Nguồn tin). Empty state surfaces a hint
/// to add feeds; click row opens the article in the default browser.
struct PlanReadingCard: View {
    @EnvironmentObject private var news: NewsFeedCoordinator
    let palette: BriefingPalette

    var body: some View {
        PlanCardChrome(
            title: "Tin đáng đọc",
            sourceLabel: "RSS",
            sourceIconLabel: "R",
            sourceIconColor: palette.coral,
            count: news.items.count,
            countSuffix: countSuffix,
            palette: palette
        ) {
            if news.isLoading && news.items.isEmpty {
                loadingState
            } else if news.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var countSuffix: String {
        news.items.isEmpty ? "" : "bài"
    }

    @ViewBuilder private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Đang tải feed…")
                .font(.system(size: 12.5, design: .serif).italic())
                .foregroundColor(palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headlineForEmpty)
                .font(.system(size: 12.5, design: .serif).italic())
                .foregroundColor(palette.ink3)
            if let err = news.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(palette.coral)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var headlineForEmpty: String {
        if news.hasConfiguredFeeds {
            return "Feed đã cấu hình nhưng chưa lấy được bài nào."
        }
        return "Chưa có nguồn tin nào — thêm RSS qua Cài đặt → Daily."
    }

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(news.items.prefix(8)) { item in
                row(item)
            }
        }
    }

    @ViewBuilder private func row(_ item: NewsItemDTO) -> some View {
        Button {
            if let url = URL(string: item.link) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.feedLabel.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .kerning(1.4)
                        .foregroundColor(palette.coral)
                    if let d = item.publishedAt {
                        Text("·").foregroundColor(palette.line2)
                        Text(relativeDate(d))
                            .font(.system(size: 10))
                            .foregroundColor(palette.ink3)
                    }
                }
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(palette.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Divider().background(palette.line), alignment: .top)
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
