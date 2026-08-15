import SwiftUI

/// Shared Aurora Glass design tokens, ported 1:1 from the approved mockup
/// (`option-4-aurora.html`, `:root` custom properties + `.card`/`.chip`
/// colors). Kept `internal` (default) so `NewsTopBar`, `NewsCardView`, and
/// `RepoCardView` reference the same palette without redefining it.
enum NewsAuroraStyle {
    static let ink = Color(red: 0x18 / 255, green: 0x1a / 255, blue: 0x2a / 255)
    static let muted = Color(red: 0x5b / 255, green: 0x5f / 255, blue: 0x7a / 255)
    static let line = Color.white.opacity(0.55)
    static let violet = Color(red: 0x7c / 255, green: 0x5c / 255, blue: 1.0)
    static let cyan = Color(red: 0x22 / 255, green: 0xd3 / 255, blue: 0xee / 255)
    static let green = Color(red: 0x34 / 255, green: 0xd3 / 255, blue: 0x99 / 255)
    static let glass = Color.white.opacity(0.62)

    /// `.card` glass fill + border, reused by both card types.
    static func cardBackground(cornerRadius: CGFloat = 20) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(glass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(line, lineWidth: 1)
            )
            .shadow(color: violet.opacity(0.22), radius: 24, x: 0, y: 14)
    }

    /// The pastel mesh-gradient page background (`body { background: … }`).
    static var meshBackground: some View {
        ZStack {
            Color(red: 0xf2 / 255, green: 0xf0 / 255, blue: 0xfb / 255)
            RadialGradient(colors: [Color(red: 0xdc / 255, green: 0xd3 / 255, blue: 1.0), .clear],
                           center: UnitPoint(x: 0.12, y: 0.08), startRadius: 0, endRadius: 480)
            RadialGradient(colors: [Color(red: 0xc8 / 255, green: 0xf4 / 255, blue: 1.0), .clear],
                           center: UnitPoint(x: 0.92, y: 0.02), startRadius: 0, endRadius: 440)
            RadialGradient(colors: [Color(red: 1.0, green: 0xe0 / 255, blue: 0xec / 255), .clear],
                           center: UnitPoint(x: 0.85, y: 0.95), startRadius: 0, endRadius: 480)
            RadialGradient(colors: [Color(red: 0xd6 / 255, green: 1.0, blue: 0xe9 / 255), .clear],
                           center: UnitPoint(x: 0.05, y: 1.0), startRadius: 0, endRadius: 440)
        }
        .ignoresSafeArea()
    }
}

/// Root layout for the News window — port of `option-4-aurora.html`: pastel
/// mesh background, a sticky glass top bar, category tab pills, and two
/// card sections ("Tin nổi bật" / "Repo GitHub cho bạn").
struct NewsDashboardView: View {
    @EnvironmentObject private var store: NewsStore
    /// `nil` == "Tất cả" (no filter) — matches the mockup's first tab.
    /// Ignored while `showingSaved` is true.
    @State private var selectedCategory: NewsCategory?
    /// "Đã lưu" pill — a separate mode rather than a `NewsCategory` case
    /// since saved items span every category and live outside the normal
    /// feed/retention lifecycle.
    @State private var showingSaved = false
    /// Non-nil while the in-app reading view is open (tapping a card sets
    /// this instead of opening the browser).
    @State private var detailItem: NewsCard?

    private let gridColumns = [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 18)]

    var body: some View {
        ZStack {
            NewsAuroraStyle.meshBackground
            VStack(spacing: 0) {
                NewsTopBar()
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        categoryTabs
                        if let error = store.error {
                            errorBanner(error)
                        }
                        if showingSaved {
                            savedSection
                        } else {
                            featuredSection
                            secondarySection
                            repoSection
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
            }

            if let detailItem {
                NewsDetailView(item: detailItem, onClose: { self.detailItem = nil })
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .animation(.easeOut(duration: 0.16), value: detailItem?.id)
        .task {
            // Only auto-load if the window opened with an empty feed (avoids
            // re-fetching every time this view re-materializes while the
            // window controller already kicked a refresh in `show()`).
            if store.feed == .empty && !store.isLoading {
                await store.refresh()
            }
        }
        .task { await store.loadSaved() }
    }

    // MARK: - Category tabs

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                tabPill(title: "Tất cả", isSelected: !showingSaved && selectedCategory == nil) {
                    showingSaved = false
                    selectedCategory = nil
                }
                ForEach(NewsCategory.allCases.filter { $0 != .other }) { category in
                    tabPill(title: category.label, isSelected: !showingSaved && selectedCategory == category) {
                        showingSaved = false
                        selectedCategory = category
                    }
                }
                tabPill(title: NewsCategory.other.label, isSelected: !showingSaved && selectedCategory == .other) {
                    showingSaved = false
                    selectedCategory = .other
                }
                tabPill(title: "★ Đã lưu", isSelected: showingSaved) {
                    showingSaved = true
                }
            }
        }
    }

    private func tabPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isSelected ? .white : NewsAuroraStyle.muted)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? NewsAuroraStyle.ink : Color.white.opacity(0.5))
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? .clear : NewsAuroraStyle.line, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Sections

    private var filteredItems: [NewsCard] {
        guard let selectedCategory else { return store.feed.items }
        return store.feed.items.filter { $0.category == selectedCategory }
    }

    /// First 1-3 items of the filtered set — the "Tin chính" hero + runners-up.
    private var featuredItems: [NewsCard] {
        Array(filteredItems.prefix(3))
    }

    /// Everything after the featured slice — the regular "Tin khác" grid.
    private var secondaryItems: [NewsCard] {
        Array(filteredItems.dropFirst(featuredItems.count))
    }

    private func openDetail(_ item: NewsCard) {
        detailItem = item
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Tin chính")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(NewsAuroraStyle.ink)
                Text("· di chuột vào thẻ để xem bản dịch đầy đủ, bấm để đọc toàn bộ")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NewsAuroraStyle.muted)
            }
            if store.isLoading && featuredItems.isEmpty {
                loadingPlaceholder
            } else if featuredItems.isEmpty {
                emptyState(text: "Chưa có tin nào trong mục này.")
            } else {
                VStack(spacing: 18) {
                    NewsCardView(item: featuredItems[0], style: .hero, onOpen: openDetail)
                    if featuredItems.count > 1 {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(featuredItems.dropFirst()) { item in
                                NewsCardView(item: item, style: .featured, onOpen: openDetail)
                            }
                        }
                    }
                }
            }
        }
    }

    private var secondarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !secondaryItems.isEmpty || (!store.isLoading && !featuredItems.isEmpty) {
                Text("Tin khác")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(NewsAuroraStyle.ink)
            }
            if !secondaryItems.isEmpty {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 18) {
                    ForEach(secondaryItems) { item in
                        NewsCardView(item: item, onOpen: openDetail)
                    }
                }
            }
        }
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tin đã lưu")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(NewsAuroraStyle.ink)
                if store.savedItems.isEmpty {
                    emptyState(text: "Chưa lưu tin nào — bấm biểu tượng bookmark trên thẻ tin để lưu.")
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 18) {
                        ForEach(store.savedItems) { item in
                            NewsCardView(item: item, onOpen: openDetail)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Repo đã lưu")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(NewsAuroraStyle.ink)
                if store.savedRepos.isEmpty {
                    emptyState(text: "Chưa lưu repo nào — bấm biểu tượng bookmark trên thẻ repo để lưu.")
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 18) {
                        ForEach(store.savedRepos) { repo in
                            RepoCardView(repo: repo)
                        }
                    }
                }
            }
        }
    }

    private var repoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Repo GitHub cho bạn")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(NewsAuroraStyle.ink)
                Text("· Go · AI · IoT")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NewsAuroraStyle.muted)
            }
            if store.feed.repos.isEmpty && !store.isLoading {
                emptyState(text: "Chưa có repo nào được đề xuất.")
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 18) {
                    ForEach(store.feed.repos) { repo in
                        RepoCardView(repo: repo)
                    }
                }
            }
        }
    }

    private var loadingPlaceholder: some View {
        HStack {
            ProgressView()
            Text("Đang tải tin…")
                .font(.system(size: 13))
                .foregroundColor(NewsAuroraStyle.muted)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private func emptyState(text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(NewsAuroraStyle.muted)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NewsAuroraStyle.ink)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}
