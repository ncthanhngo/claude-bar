import SwiftUI

/// Layout weight for `NewsCardView` — the dashboard renders a "Tin chính"
/// featured area (`.hero` for the single full-width lead item, `.featured`
/// for the 1-2 runners-up beside it) above the regular "Tin khác" adaptive
/// grid (`.grid`, the original size).
enum NewsCardStyle: Equatable {
    case grid
    case featured
    case hero

    var imageHeight: CGFloat {
        switch self {
        case .grid: return 150
        case .featured: return 190
        case .hero: return 280
        }
    }

    var titleFont: Font {
        switch self {
        case .grid: return .system(size: 16, weight: .bold)
        case .featured: return .system(size: 18, weight: .bold)
        case .hero: return .system(size: 23, weight: .heavy)
        }
    }

    var titleLineLimit: Int {
        switch self {
        case .grid: return 3
        case .featured: return 3
        case .hero: return 4
        }
    }

    var summaryLineLimit: Int {
        self == .hero ? 4 : 3
    }
}

/// One news card — port of the mockup's `.card` (image variant): source
/// image with a category chip, favicon + source + relative time, VN title,
/// VN one-line summary, and the "✦ AI" badge. Hovering reveals a full-VI
/// translation quick-peek. Clicking anywhere on the card opens the in-app
/// `NewsDetailView` (via `onOpen`) instead of the browser — "Mở bài gốc"
/// inside that view is now the only way to leave the app.
///
/// When `item.imageURL` is empty this renders a compact text-first layout
/// instead of an image header — no empty gray box, no floating badge (the
/// bug this fixes): see `compactBody`.
struct NewsCardView: View {
    let item: NewsCard
    var style: NewsCardStyle = .grid
    let onOpen: (NewsCard) -> Void

    @EnvironmentObject private var store: NewsStore
    @State private var isHovering = false

    var body: some View {
        Group {
            if item.imageURL.isEmpty {
                compactBody
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    imageHeader
                    body_
                }
            }
        }
        .background(NewsAuroraStyle.cardBackground())
        .overlay(alignment: .topLeading) { translationOverlay }
        .scaleEffect(isHovering ? 1.015 : 1)
        .offset(y: isHovering ? -3 : 0)
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { onOpen(item) }
        .pointingHandCursor()
    }

    // MARK: - Image + category chip (image variant)

    private var imageHeader: some View {
        ZStack(alignment: .topLeading) {
            AsyncImage(url: URL(string: item.imageURL)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(Color.primary.opacity(0.06))
                }
            }
            HStack {
                categoryChip
                Spacer(minLength: 0)
                bookmarkButton(tint: .white)
            }
            .padding(12)
        }
        .frame(height: style.imageHeight)
        .clipShape(RoundedCorners(radius: 20, corners: [.topLeft, .topRight]))
    }

    private var categoryChip: some View {
        let color = item.category.badgeColor
        return Text(item.category.label.uppercased())
            .font(.system(size: 10.5, weight: .heavy))
            .tracking(0.3)
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color(red: color.r, green: color.g, blue: color.b).opacity(0.88))
            )
    }

    // MARK: - Body (image variant)

    private var body_: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceRow
            titleText
            summaryText
            aiBadge
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 16)
    }

    private var sourceRow: some View {
        HStack(spacing: 7) {
            faviconView
            Text(item.sourceLabel)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(NewsAuroraStyle.muted)
            Spacer(minLength: 0)
            relativeTimeText
        }
    }

    // MARK: - Compact (no-image) variant — fixes the empty-gray-box bug.

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            compactSourceRow
            titleText
            summaryText
            aiBadge
        }
        .padding(16)
    }

    private var compactSourceRow: some View {
        HStack(spacing: 7) {
            faviconView
            Text(item.sourceLabel)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(NewsAuroraStyle.muted)
            inlineCategoryChip
            Spacer(minLength: 0)
            relativeTimeText
            bookmarkButton(tint: NewsAuroraStyle.muted)
        }
    }

    /// Small tasteful chip for the no-image layout — replaces the shouty
    /// uppercase badge that used to float over an empty gray rectangle.
    private var inlineCategoryChip: some View {
        let color = item.category.badgeColor
        return Text(item.category.label)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Color(red: color.r, green: color.g, blue: color.b))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color(red: color.r, green: color.g, blue: color.b).opacity(0.14))
            )
    }

    // MARK: - Shared bits

    private var faviconView: some View {
        Group {
            if !item.sourceFaviconURL.isEmpty, let url = URL(string: item.sourceFaviconURL) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable()
                    } else {
                        Color.primary.opacity(0.1)
                    }
                }
                .frame(width: 15, height: 15)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private var relativeTimeText: some View {
        let relative = NewsDateFormatting.relativeLabel(item.publishedAt)
        return Group {
            if !relative.isEmpty {
                Text(relative)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(NewsAuroraStyle.muted)
            }
        }
    }

    private var titleText: some View {
        Text(item.titleVI.isEmpty ? item.title : item.titleVI)
            .font(style.titleFont)
            .foregroundColor(NewsAuroraStyle.ink)
            .lineLimit(style.titleLineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var summaryText: some View {
        if !item.summaryVI.isEmpty {
            Text(item.summaryVI)
                .font(.system(size: 13))
                .foregroundColor(Color(red: 0x3f / 255, green: 0x42 / 255, blue: 0x60 / 255))
                .lineLimit(style.summaryLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiBadge: some View {
        Text("✦ AI tóm tắt & dịch")
            .font(.system(size: 11, weight: .heavy))
            .foregroundColor(NewsAuroraStyle.violet)
    }

    /// Bookmark toggle — placed inline in the source row (compact layout) or
    /// as a corner overlay on the image (image layout). Stops the card's own
    /// tap gesture from firing when tapped (Button hit-tests before the
    /// parent's `.onTapGesture`).
    private func bookmarkButton(tint: Color) -> some View {
        let saved = store.isItemSaved(item.id)
        return Button {
            Task { await store.toggleSaveItem(item) }
        } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(saved ? NewsAuroraStyle.violet : tint)
                .padding(6)
                .background(Circle().fill(Color.white.opacity(saved ? 0.9 : 0.55)))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Hover translation overlay (quick-peek)

    @ViewBuilder
    private var translationOverlay: some View {
        if isHovering && !item.fullVI.isEmpty {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0x1f / 255, green: 0x19 / 255, blue: 0x3c / 255).opacity(0.96),
                                 Color(red: 0x14 / 255, green: 0x1e / 255, blue: 0x37 / 255).opacity(0.96)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(alignment: .topLeading) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("BẢN DỊCH ĐẦY ĐỦ")
                                .font(.system(size: 10.5, weight: .heavy))
                                .tracking(0.4)
                                .foregroundColor(Color(red: 0xc4 / 255, green: 0xb5 / 255, blue: 0xfd / 255))
                            Text(item.fullVI)
                                .font(.system(size: 13))
                                .foregroundColor(Color(red: 0xe7 / 255, green: 0xe2 / 255, blue: 1.0))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                    }
                }
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

/// Rounds only the given corners — used to keep the image header's bottom
/// edge square against the text body below it.
struct RoundedCorners: Shape {
    var radius: CGFloat
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
}
