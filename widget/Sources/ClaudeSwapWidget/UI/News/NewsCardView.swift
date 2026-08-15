import SwiftUI

/// One news card — port of the mockup's `.card` (image variant): source
/// image with a category chip, favicon + source + relative time, VN title,
/// VN one-line summary, and the "✦ AI" badge. Hovering reveals a full-VI
/// translation overlay (mirrors `.card:hover .trans { opacity:1 }`).
/// Clicking anywhere on the card opens `originalURL` in the default browser.
struct NewsCardView: View {
    let item: NewsCard
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            imageHeader
            body_
        }
        .background(NewsAuroraStyle.cardBackground())
        .overlay(alignment: .topLeading) { translationOverlay }
        .scaleEffect(isHovering ? 1.015 : 1)
        .offset(y: isHovering ? -3 : 0)
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { openOriginal() }
        .pointingHandCursor()
    }

    // MARK: - Image + category chip

    private var imageHeader: some View {
        ZStack(alignment: .topLeading) {
            if !item.imageURL.isEmpty, let url = URL(string: item.imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.primary.opacity(0.06))
                    }
                }
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
            }
            categoryChip
                .padding(12)
        }
        .frame(height: 150)
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

    // MARK: - Body

    private var body_: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceRow
            Text(item.titleVI.isEmpty ? item.title : item.titleVI)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(NewsAuroraStyle.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !item.summaryVI.isEmpty {
                Text(item.summaryVI)
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0x3f / 255, green: 0x42 / 255, blue: 0x60 / 255))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("✦ AI tóm tắt & dịch")
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(NewsAuroraStyle.violet)
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 16)
    }

    private var sourceRow: some View {
        HStack(spacing: 7) {
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
            Text(item.sourceLabel)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(NewsAuroraStyle.muted)
            Spacer(minLength: 0)
            let relative = NewsDateFormatting.relativeLabel(item.publishedAt)
            if !relative.isEmpty {
                Text(relative)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(NewsAuroraStyle.muted)
            }
        }
    }

    // MARK: - Hover translation overlay

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
        }
    }

    private func openOriginal() {
        guard !item.originalURL.isEmpty, let url = URL(string: item.originalURL) else { return }
        NSWorkspace.shared.open(url)
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
