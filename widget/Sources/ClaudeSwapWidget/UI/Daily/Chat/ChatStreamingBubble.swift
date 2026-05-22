import SwiftUI

/// Live assistant bubble shown while a SendMessage stream is open. Two
/// visual phases:
///  - **Thinking** (no chunks decoded yet): a Claude-CLI-style sparkle glyph
///    cycling through `✻✺✹✸✷` + "Đang nghĩ" + animated three-dot ellipsis.
///    Reassures the user that the request is in flight before the first
///    token lands.
///  - **Typing** (at least one chunk decoded): the typewritten text from
///    `chatStore.streamingText` with a blinking caret at the tail. The pace
///    is smoothed by `TypewriterRenderer` so chunks reveal at reading speed.
///
/// Isolated from the message list so its high-frequency redraws don't churn
/// the LazyVStack above it.
struct ChatStreamingBubble: View {
    @EnvironmentObject private var chatStore: ChatStore
    let palette: BriefingPalette
    @State private var caretOn: Bool = true

    var body: some View {
        if chatStore.isSending || chatStore.streamingText != nil {
            HStack(alignment: .top, spacing: 14) {
                Rectangle()
                    .fill(palette.rose)
                    .frame(width: 2)
                    .opacity(0.75)
                VStack(alignment: .leading, spacing: 10) {
                    eyebrow
                    bodyContent
                }
                Spacer(minLength: 0)
            }
            .onAppear { startBlink() }
        }
    }

    @ViewBuilder private var eyebrow: some View {
        HStack(spacing: 8) {
            Text("CLAUDE")
                .kerning(1.5)
                .font(palette.chatEyebrowFont)
                .foregroundColor(palette.ink3)
            Text(eyebrowSubtitle)
                .font(.system(size: 10.5, design: .serif).italic())
                .foregroundColor(palette.ink3)
        }
    }

    private var eyebrowSubtitle: String {
        hasVisibleText ? "đang gõ…" : "vừa nhận câu hỏi"
    }

    @ViewBuilder private var bodyContent: some View {
        if hasVisibleText, let text = chatStore.streamingText {
            Text(displayText(text))
                .font(palette.chatBodyFont)
                .foregroundColor(palette.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ThinkingIndicator(palette: palette)
        }
    }

    private var hasVisibleText: Bool {
        if let t = chatStore.streamingText, !t.isEmpty { return true }
        return false
    }

    /// Append a trailing caret block to the typewritten text. Caret is a
    /// unicode left-half block we toggle opacity on via `caretOn` — keeps the
    /// redraw cheap (no view-tree churn, just an attribute swap).
    private func displayText(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        var caret = AttributedString("▍")
        caret.foregroundColor = caretOn ? palette.coral : .clear
        attr.append(caret)
        return attr
    }

    private func startBlink() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            DispatchQueue.main.async {
                if chatStore.streamingText == nil && !chatStore.isSending {
                    timer.invalidate()
                    return
                }
                caretOn.toggle()
            }
        }
    }
}

/// "✻ Đang nghĩ ..." indicator shown before the first token arrives. The
/// sparkle glyph cycles through five Unicode asterisks at ~6 fps and the
/// trailing ellipsis grows from one to three dots at ~3 fps — the same
/// rhythm Claude CLI uses in the terminal.
private struct ThinkingIndicator: View {
    let palette: BriefingPalette

    private static let sparkles: [String] = ["✻", "✺", "✹", "✸", "✷"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let sparkleIdx = Int(t * 6) % Self.sparkles.count
            let dotCount = (Int(t * 3) % 4)
            HStack(spacing: 8) {
                Text(Self.sparkles[sparkleIdx])
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(palette.coral)
                Text("Đang nghĩ")
                    .font(.system(size: 13.5, design: .serif).italic())
                    .foregroundColor(palette.ink2)
                Text(String(repeating: ".", count: dotCount))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(palette.ink2)
                    .frame(width: 22, alignment: .leading)
            }
        }
    }
}
