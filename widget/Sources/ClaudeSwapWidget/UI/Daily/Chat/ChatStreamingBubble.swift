import SwiftUI

/// Lightweight bubble that re-renders on every `chatStore.streamingText`
/// update (~30 Hz via DeltaBatcher). Isolated from the message list so the
/// whole thread doesn't redraw on each chunk.
struct ChatStreamingBubble: View {
    @EnvironmentObject private var chatStore: ChatStore
    let palette: BriefingPalette
    @State private var caretOn: Bool = true

    var body: some View {
        if let text = chatStore.streamingText {
            HStack(alignment: .top, spacing: 14) {
                Rectangle()
                    .fill(palette.rose)
                    .frame(width: 2)
                    .opacity(0.75)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("CLAUDE")
                            .kerning(1.5)
                            .font(palette.chatEyebrowFont)
                            .foregroundColor(palette.ink3)
                        Text("đang gõ…")
                            .font(.system(size: 10.5, design: .serif).italic())
                            .foregroundColor(palette.ink3)
                    }
                    Text(displayText(text))
                        .font(palette.chatBodyFont)
                        .foregroundColor(palette.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .onAppear { startBlink() }
        }
    }

    /// Append a trailing caret block when the buffer doesn't already end on
    /// whitespace. Caret is a unicode FULL BLOCK we toggle opacity on via the
    /// caretOn state — keeps the redraw cheap.
    private func displayText(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let caret = AttributedString("▍")
        var caretCopy = caret
        caretCopy.foregroundColor = caretOn ? palette.coral : .clear
        attr.append(caretCopy)
        return attr
    }

    private func startBlink() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            DispatchQueue.main.async {
                if chatStore.streamingText == nil {
                    timer.invalidate()
                    return
                }
                caretOn.toggle()
            }
        }
    }
}
