import SwiftUI

/// Live assistant bubble shown while a SendMessage stream is open. Two
/// visual phases:
///  - **Thinking** (no chunks decoded yet): a Claude-CLI-style sparkle glyph
///    cycling through `✻✺✹✸✷` + "Đang nghĩ" + animated three-dot ellipsis.
///    Reassures the user that the request is in flight before the first
///    token lands.
///  - **Typing** (at least one chunk decoded): the streamed text rendered
///    through `ChatMarkdownView` so headings / lists / emphasis show as
///    formatted output instead of raw `#`, `**`, `-` markers. A blinking
///    caret is appended inline to the last paragraph via the view's
///    `trailingInline` parameter.
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
            ChatMarkdownView(
                text: text,
                palette: palette,
                trailingInline: caretInline
            )
        } else {
            ThinkingIndicator(palette: palette)
        }
    }

    private var hasVisibleText: Bool {
        if let t = chatStore.streamingText, !t.isEmpty { return true }
        return false
    }

    /// Caret as a pre-styled AttributedString. Toggling `caretOn` swaps the
    /// foreground between coral and clear — fixed-width glyph means the
    /// layout never reflows on blink.
    ///
    /// Sendability note: `AttributedString.foregroundColor` setter and
    /// `AttributeContainer.foregroundColor` both internally form a KeyPath
    /// over `SwiftUIAttributes.ForegroundColorAttribute` which is non-Sendable
    /// in current SDKs (Apple bug — `<unknown>:0` warning under
    /// `-strict-concurrency=complete`). This is a benign SDK-level warning;
    /// the closure here doesn't actually cross actor boundaries.
    private var caretInline: AttributedString {
        var attr = AttributedString("▍")
        attr.foregroundColor = caretOn ? palette.coral : .clear
        return attr
    }

    private func startBlink() {
        // Drive the caret blink off an async sleep loop instead of Timer so
        // the closure stays Sendable. The view is created once per stream and
        // torn down on .onDisappear via SwiftUI's structural lifecycle, so
        // the loop self-terminates the same moment the bubble disappears.
        Task { @MainActor in
            while chatStore.streamingText != nil || chatStore.isSending {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard chatStore.streamingText != nil || chatStore.isSending else { return }
                caretOn.toggle()
            }
        }
    }
}

/// "✻ Đang nghĩ ..." indicator shown before the first token arrives. The
/// sparkle glyph cycles through five Unicode asterisks at ~6 fps and the
/// trailing ellipsis grows from one to three dots at ~3 fps — same rhythm
/// Claude CLI uses in the terminal. Each dot occupies a fixed slot whose
/// visibility toggles via opacity, so the row never reflows mid-cycle (the
/// previous implementation used a variable-width `String(repeating:)` that
/// caused the third dot to wrap onto a new line at certain widths).
private struct ThinkingIndicator: View {
    let palette: BriefingPalette

    private static let sparkles: [String] = ["✻", "✺", "✹", "✸", "✷"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let sparkleIdx = Int(t * 6) % Self.sparkles.count
            let dotCount = (Int(t * 3) % 3) + 1
            HStack(spacing: 8) {
                Text(Self.sparkles[sparkleIdx])
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(palette.coral)
                Text("Đang nghĩ")
                    .font(.system(size: 13.5, design: .serif).italic())
                    .foregroundColor(palette.ink2)
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        Text(".")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(palette.ink2)
                            .opacity(i < dotCount ? 1 : 0)
                    }
                }
            }
        }
    }
}
