import SwiftUI

/// Floating card that RENDERS a group's markdown note (not raw text): headings,
/// bullet/numbered lists and blockquotes become real blocks, while inline
/// **bold**, *italic*, `code` and [links](url) render within each line. SwiftUI's
/// `Text(AttributedString)` only styles inline runs, so block elements are split
/// out here and laid out as views — that's what makes `# H` and `- item` look
/// like a heading and a bullet instead of literal markdown.
struct NetbirdNoteCard: View {
    let note: String
    let palette: BriefingPalette

    var body: some View {
        ScrollView {
            NetbirdNoteBody(note: note, palette: palette)
        }
        .frame(width: 300)
        .frame(maxHeight: 240)
        .background(palette.raisedSurface)
    }
}

/// The laid-out markdown blocks without the scroll container. Split out so it
/// renders with an intrinsic height (ImageRenderer/snapshots collapse a bare
/// ScrollView to blank) while the card keeps scrolling for long notes.
struct NetbirdNoteBody: View {
    let note: String
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(MarkdownNoteBlock.parse(note).enumerated()), id: \.offset) { _, block in
                block.view(palette: palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(palette.raisedSurface)
    }
}

/// One rendered line of a markdown note. A deliberately small subset — the
/// common things an admin jots in a group note — kept dependency-free.
enum MarkdownNoteBlock {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case ordered(marker: String, text: String)
    case quote(text: String)
    case paragraph(text: String)
    case blank

    static func parse(_ md: String) -> [MarkdownNoteBlock] {
        md.components(separatedBy: "\n").map { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .blank }
            if t.hasPrefix("### ") { return .heading(level: 3, text: String(t.dropFirst(4))) }
            if t.hasPrefix("## ") { return .heading(level: 2, text: String(t.dropFirst(3))) }
            if t.hasPrefix("# ") { return .heading(level: 1, text: String(t.dropFirst(2))) }
            if t.hasPrefix("> ") { return .quote(text: String(t.dropFirst(2))) }
            if t.hasPrefix("- ") || t.hasPrefix("* ") { return .bullet(text: String(t.dropFirst(2))) }
            if let dot = t.firstIndex(of: "."),
               t.distance(from: t.startIndex, to: dot) <= 3,
               t[t.startIndex..<dot].allSatisfy(\.isNumber),
               t.index(after: dot) < t.endIndex, t[t.index(after: dot)] == " " {
                return .ordered(marker: String(t[t.startIndex...dot]),
                                text: String(t[t.index(dot, offsetBy: 2)...]))
            }
            return .paragraph(text: t)
        }
    }

    /// Inline markdown (bold/italic/code/link) within a single line.
    private static func inline(_ s: String) -> Text {
        if let a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) { return Text(a) }
        return Text(s)
    }

    @ViewBuilder func view(palette: BriefingPalette) -> some View {
        switch self {
        case let .heading(level, text):
            let size: CGFloat = level == 1 ? 16 : level == 2 ? 14 : 12.5
            Self.inline(text).font(.system(size: size, weight: .bold))
                .foregroundColor(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case let .bullet(text):
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(.system(size: 12)).foregroundColor(palette.ink2)
                Self.inline(text).font(.system(size: 12)).foregroundColor(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .ordered(marker, text):
            HStack(alignment: .top, spacing: 6) {
                Text(marker).font(.system(size: 12, weight: .medium)).foregroundColor(palette.ink2)
                Self.inline(text).font(.system(size: 12)).foregroundColor(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .quote(text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(palette.line2).frame(width: 2)
                Self.inline(text).font(.system(size: 12)).italic().foregroundColor(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .paragraph(text):
            Self.inline(text).font(.system(size: 12)).foregroundColor(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .blank:
            Color.clear.frame(height: 3)
        }
    }
}

/// Shows `note` in a popover while the hovered view is under the cursor. A short
/// close-debounce stops the popover flickering as the pointer crosses the gap
/// between the source and the detached popover window. No-op when `note` is nil
/// or empty, so it costs nothing on groups without a note.
private struct NetbirdNoteHoverModifier: ViewModifier {
    let note: String?
    let palette: BriefingPalette
    @State private var show = false
    @State private var closeTask: Task<Void, Never>?

    private var hasNote: Bool { !(note ?? "").isEmpty }

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hasNote else { return }
                closeTask?.cancel()
                if hovering {
                    show = true
                } else {
                    closeTask = Task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        if !Task.isCancelled { show = false }
                    }
                }
            }
            .popover(isPresented: $show, arrowEdge: .top) {
                if let n = note, !n.isEmpty {
                    NetbirdNoteCard(note: n, palette: palette)
                }
            }
    }
}

extension View {
    /// Attach a hover-to-reveal markdown note popover to any view.
    func netbirdNoteHover(_ note: String?, palette: BriefingPalette) -> some View {
        modifier(NetbirdNoteHoverModifier(note: note, palette: palette))
    }
}
