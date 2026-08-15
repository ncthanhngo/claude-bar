import SwiftUI

/// In-app reading view — presented as a dim overlay on top of
/// `NewsDashboardView` when a `NewsCardView` is tapped (replaces the old
/// "click opens browser" behaviour; the hover quick-peek on the card stays).
///
/// Loads the FULL Vietnamese translation via `csw news article --url` — slow
/// (runs the local model), so this shows a spinner over the item's own
/// `fullVI`/`summaryVI` while it waits, then swaps in the richer
/// paragraph-by-paragraph translation on success. On fetch failure it just
/// keeps showing the feed-level translation (already visible) with a soft
/// error note instead of blocking the read.
struct NewsDetailView: View {
    let item: NewsCard
    let onClose: () -> Void

    @EnvironmentObject private var store: NewsStore
    @State private var article: ArticleDTO?
    @State private var isLoadingArticle = true
    @State private var loadNote: String?

    private let client = CswClient()

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                header
                Divider().overlay(NewsAuroraStyle.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !item.imageURL.isEmpty { heroImage }
                        metaRow
                        Text(displayTitle)
                            .font(.system(size: 21, weight: .bold))
                            .foregroundColor(NewsAuroraStyle.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        translationBody
                    }
                    .padding(20)
                }
                Divider().overlay(NewsAuroraStyle.line)
                footer
            }
            .frame(maxWidth: 720, maxHeight: 640)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(NewsAuroraStyle.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
            .padding(28)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .task(id: item.id) { await loadArticle() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if !item.sourceFaviconURL.isEmpty, let url = URL(string: item.sourceFaviconURL) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable()
                    } else {
                        Color.primary.opacity(0.1)
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text(item.sourceLabel.isEmpty ? "Nguồn tin" : item.sourceLabel)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(NewsAuroraStyle.muted)
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(NewsAuroraStyle.muted)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(16)
    }

    // MARK: - Hero image

    private var heroImage: some View {
        AsyncImage(url: URL(string: item.imageURL)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Rectangle().fill(Color.primary.opacity(0.06))
            }
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Meta row (category chip + relative time)

    private var metaRow: some View {
        let color = item.category.badgeColor
        return HStack(spacing: 8) {
            Text(item.category.label)
                .font(.system(size: 10.5, weight: .heavy))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(red: color.r, green: color.g, blue: color.b).opacity(0.88)))
            let relative = NewsDateFormatting.relativeLabel(item.publishedAt)
            if !relative.isEmpty {
                Text(relative)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(NewsAuroraStyle.muted)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var translationBody: some View {
        if isLoadingArticle {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Đang dịch toàn văn…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(NewsAuroraStyle.muted)
            }
            .padding(.bottom, 4)
        }
        if let note = loadNote {
            Text(note)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.orange)
        }
        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
            Text(paragraph)
                .font(.system(size: 14))
                .foregroundColor(Color(red: 0x3f / 255, green: 0x42 / 255, blue: 0x60 / 255))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
        if paragraphs.isEmpty && !isLoadingArticle {
            Text("Chưa có nội dung dịch cho bài này.")
                .font(.system(size: 13))
                .foregroundColor(NewsAuroraStyle.muted)
        }
    }

    private var displayTitle: String {
        if let article, !article.titleVI.isEmpty { return article.titleVI }
        return item.titleVI.isEmpty ? item.title : item.titleVI
    }

    /// Prefers the full-article translation; falls back to the feed item's
    /// own `fullVI`/`summaryVI` while loading or on failure (contract.md:
    /// "contentVI may fall back to the item's feed summary").
    private var paragraphs: [String] {
        let text: String
        if let article, article.ok, !article.contentVI.isEmpty {
            text = article.contentVI
        } else if !item.fullVI.isEmpty {
            text = item.fullVI
        } else {
            text = item.summaryVI
        }
        return text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Footer actions

    private var footer: some View {
        HStack(spacing: 10) {
            saveButton
            Spacer(minLength: 0)
            Button(action: openOriginal) {
                Text("Mở bài gốc")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [NewsAuroraStyle.violet, NewsAuroraStyle.cyan],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(item.originalURL.isEmpty)
        }
        .padding(16)
    }

    private var saveButton: some View {
        let saved = store.isItemSaved(item.id)
        return Button {
            Task { await store.toggleSaveItem(item) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: saved ? "bookmark.fill" : "bookmark")
                Text(saved ? "Bỏ lưu" : "Lưu")
            }
            .font(.system(size: 12.5, weight: .bold))
            .foregroundColor(saved ? .white : NewsAuroraStyle.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(saved ? AnyShapeStyle(NewsAuroraStyle.violet) : AnyShapeStyle(Color.white.opacity(0.6)))
            )
            .overlay(Capsule().strokeBorder(NewsAuroraStyle.line, lineWidth: saved ? 0 : 1))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func openOriginal() {
        guard !item.originalURL.isEmpty, let url = URL(string: item.originalURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadArticle() async {
        isLoadingArticle = true
        loadNote = nil
        defer { isLoadingArticle = false }
        guard !item.originalURL.isEmpty else {
            loadNote = "Không có liên kết bài gốc — hiển thị bản tóm tắt."
            return
        }
        do {
            let result = try await client.newsArticle(url: item.originalURL)
            article = result
            if !result.ok {
                loadNote = result.error.isEmpty
                    ? "Không tải được bản dịch đầy đủ — hiển thị bản tóm tắt."
                    : result.error
            }
        } catch {
            loadNote = "Không tải được bản dịch đầy đủ — hiển thị bản tóm tắt."
        }
    }
}
