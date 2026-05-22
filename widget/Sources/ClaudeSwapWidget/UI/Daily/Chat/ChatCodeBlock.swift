import SwiftUI

/// Renders one ```fenced``` code block in monospace on a paper2 background.
/// MVP has no syntax highlighting — the value is the visual demarcation +
/// horizontal scrolling for wide lines.
struct ChatCodeBlock: View {
    let code: String
    let language: String?
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                Text(lang.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .kerning(1.4)
                    .foregroundColor(palette.ink3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(palette.chatMonoFont)
                    .foregroundColor(palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(palette.paper2)
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(palette.line2, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Parses a plain-text assistant response into alternating text + code-block
/// segments. The parser is intentionally simple: it splits on ``` markers
/// and treats anything between matched pairs as code. Unmatched ``` falls
/// back to plain text. No language detection beyond the optional info string
/// on the opening fence (```swift ⇒ language = "swift").
enum ChatSegment: Identifiable, Hashable {
    case text(String)
    case code(language: String?, body: String)

    var id: String {
        switch self {
        case .text(let s): return "t:\(s.hashValue)"
        case .code(let lang, let body): return "c:\(lang ?? "")|\(body.hashValue)"
        }
    }
}

enum ChatFenceParser {
    /// Splits the input into segments. ```lang\n…\n``` becomes a .code
    /// segment; everything else is .text.
    static func segments(of plain: String) -> [ChatSegment] {
        var result: [ChatSegment] = []
        let lines = plain.components(separatedBy: "\n")
        var i = 0
        var textBuf: [String] = []
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                if !textBuf.isEmpty {
                    result.append(.text(textBuf.joined(separator: "\n")))
                    textBuf.removeAll()
                }
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeBuf: [String] = []
                while i < lines.count, !lines[i].hasPrefix("```") {
                    codeBuf.append(lines[i])
                    i += 1
                }
                result.append(.code(language: lang.isEmpty ? nil : lang,
                                    body: codeBuf.joined(separator: "\n")))
                if i < lines.count { i += 1 } // consume closing fence
            } else {
                textBuf.append(line)
                i += 1
            }
        }
        if !textBuf.isEmpty {
            result.append(.text(textBuf.joined(separator: "\n")))
        }
        return result
    }
}
