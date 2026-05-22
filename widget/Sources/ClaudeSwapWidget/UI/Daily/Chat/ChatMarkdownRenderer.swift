import SwiftUI

/// Block-level markdown nodes parsed from an assistant response. Code fences
/// (```) are NOT handled here — the outer `ChatFenceParser` splits text vs.
/// code first, and this parser runs over each `.text` segment so code blocks
/// keep their dedicated monospace bubble.
enum ChatMarkdownBlock {
    case heading(level: Int, inline: AttributedString)
    case paragraph(AttributedString)
    case bulletList(items: [AttributedString])
    case orderedList(start: Int, items: [AttributedString])
    case blockquote(AttributedString)
    case rule
}

/// Minimal block-level markdown parser. Handles ATX headings (`#…######`),
/// unordered lists (`-`, `*`, `•`), ordered lists (`1.`), blockquotes (`>`),
/// horizontal rules (`---` / `***` / `___`) and paragraphs. Inline emphasis
/// (`**bold**`, `*italic*`, `` `code` ``, `[link](url)`) is delegated to
/// `AttributedString(markdown:)` per-block so the styling matches Apple's
/// own markdown rendering elsewhere in the system.
enum ChatMarkdownParser {
    static func parse(_ text: String) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule); i += 1; continue
            }

            if let lvl = headingLevel(trimmed) {
                let body = String(trimmed.drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: lvl, inline: inlineAttr(body)))
                i += 1; continue
            }

            if trimmed.hasPrefix(">") {
                var qLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    qLines.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(inlineAttr(qLines.joined(separator: " "))))
                continue
            }

            if bulletBody(trimmed) != nil {
                var items: [AttributedString] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let body = bulletBody(t) else { break }
                    items.append(inlineAttr(body))
                    i += 1
                }
                blocks.append(.bulletList(items: items))
                continue
            }

            if let (start, _) = orderedPrefix(trimmed) {
                var items: [AttributedString] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let (_, body) = orderedPrefix(t) else { break }
                    items.append(inlineAttr(body))
                    i += 1
                }
                blocks.append(.orderedList(start: start, items: items))
                continue
            }

            var paraLines: [String] = []
            while i < lines.count {
                let r = lines[i]
                let t = r.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if isBlockStart(t) { break }
                paraLines.append(r)
                i += 1
            }
            let joined = paraLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(inlineAttr(joined)))
            }
        }
        return blocks
    }

    private static func isBlockStart(_ t: String) -> Bool {
        if headingLevel(t) != nil { return true }
        if t.hasPrefix(">") { return true }
        if bulletBody(t) != nil { return true }
        if orderedPrefix(t) != nil { return true }
        if t == "---" || t == "***" || t == "___" { return true }
        return false
    }

    /// Number of leading `#` (1–6) iff followed by a space. nil otherwise.
    private static func headingLevel(_ t: String) -> Int? {
        var n = 0
        for ch in t { if ch == "#" { n += 1 } else { break } }
        guard n >= 1 && n <= 6 else { return nil }
        let after = t.dropFirst(n)
        return after.first == " " ? n : nil
    }

    /// Returns the bullet body if the line is `- `, `* `, or `• ` (or a bare
    /// marker on its own line). nil otherwise.
    private static func bulletBody(_ t: String) -> String? {
        for marker in ["- ", "* ", "• "] where t.hasPrefix(marker) {
            return String(t.dropFirst(marker.count))
        }
        if t == "-" || t == "*" || t == "•" { return "" }
        return nil
    }

    /// Returns (startIndex, body) if the line matches `\d+\. body`.
    private static func orderedPrefix(_ t: String) -> (Int, String)? {
        var s = Substring(t)
        var digits = ""
        while let c = s.first, c.isASCII, c.isNumber {
            digits.append(c); s = s.dropFirst()
        }
        guard !digits.isEmpty, let num = Int(digits) else { return nil }
        guard s.first == "." else { return nil }
        s = s.dropFirst()
        guard s.first == " " else { return nil }
        return (num, String(s.dropFirst()))
    }

    /// Parses inline markdown (bold/italic/code/links) into an AttributedString.
    /// Falls back to plain text if the input has unmatched markers — the parser
    /// throws on malformed input rather than partial-renders.
    private static func inlineAttr(_ s: String) -> AttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        opts.allowsExtendedAttributes = false
        if let attr = try? AttributedString(markdown: s, options: opts) {
            return attr
        }
        return AttributedString(s)
    }
}

/// SwiftUI view that renders parsed markdown blocks with the chat palette's
/// fonts and ink colors. The optional `trailingInline` is appended to the
/// last appendable block — used during streaming so the blinking caret sits
/// at the end of the last sentence rather than on its own row.
struct ChatMarkdownView: View {
    let text: String
    let palette: BriefingPalette
    var trailingInline: AttributedString? = nil

    var body: some View {
        let blocks = renderedBlocks
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedBlocks: [ChatMarkdownBlock] {
        let parsed = ChatMarkdownParser.parse(text)
        guard let suffix = trailingInline else { return parsed }
        return appendTrailing(suffix, to: parsed)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let inline):
            Text(inline)
                .font(headingFont(level))
                .foregroundColor(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .paragraph(let inline):
            Text(inline)
                .font(palette.chatBodyFont)
                .foregroundColor(palette.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", text: item, monoDigit: false)
                }
            }
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    listRow(marker: "\(start + idx).", text: item, monoDigit: true)
                }
            }
        case .blockquote(let inline):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(palette.ink3)
                    .frame(width: 2)
                    .opacity(0.55)
                Text(inline)
                    .font(.system(size: 14.5, design: .serif).italic())
                    .foregroundColor(palette.ink2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        case .rule:
            Rectangle()
                .fill(palette.ink3.opacity(0.25))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func listRow(marker: String, text: AttributedString, monoDigit: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(monoDigit ? palette.chatBodyFont.monospacedDigit() : palette.chatBodyFont)
                .foregroundColor(palette.ink2)
            Text(text)
                .font(palette.chatBodyFont)
                .foregroundColor(palette.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 21, weight: .bold, design: .serif)
        case 2: return .system(size: 18, weight: .bold, design: .serif)
        case 3: return .system(size: 16, weight: .semibold, design: .serif)
        default: return .system(size: 15, weight: .semibold)
        }
    }

    /// Append `suffix` to the inline content of the last block, so a blinking
    /// caret can be rendered inline at the streaming tail instead of dropping
    /// onto its own row. If the last block isn't text-appendable (rule, empty
    /// list), the suffix becomes a trailing paragraph.
    private func appendTrailing(
        _ suffix: AttributedString,
        to blocks: [ChatMarkdownBlock]
    ) -> [ChatMarkdownBlock] {
        guard !blocks.isEmpty else { return [.paragraph(suffix)] }
        var out = blocks
        let lastIdx = out.count - 1
        switch out[lastIdx] {
        case .paragraph(let s):
            var copy = s; copy.append(suffix)
            out[lastIdx] = .paragraph(copy)
        case .heading(let lvl, let s):
            var copy = s; copy.append(suffix)
            out[lastIdx] = .heading(level: lvl, inline: copy)
        case .blockquote(let s):
            var copy = s; copy.append(suffix)
            out[lastIdx] = .blockquote(copy)
        case .bulletList(var items):
            if items.isEmpty {
                out.append(.paragraph(suffix))
            } else {
                var copy = items[items.count - 1]
                copy.append(suffix)
                items[items.count - 1] = copy
                out[lastIdx] = .bulletList(items: items)
            }
        case .orderedList(let start, var items):
            if items.isEmpty {
                out.append(.paragraph(suffix))
            } else {
                var copy = items[items.count - 1]
                copy.append(suffix)
                items[items.count - 1] = copy
                out[lastIdx] = .orderedList(start: start, items: items)
            }
        case .rule:
            out.append(.paragraph(suffix))
        }
        return out
    }
}
