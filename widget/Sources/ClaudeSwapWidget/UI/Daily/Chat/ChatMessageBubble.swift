import SwiftUI

/// Renders one message in the thread. Two visual variants: user (right-
/// aligned paper2 capsule) and assistant (full-width body with a rose
/// accent bar like an editorial pull-quote).
struct ChatMessageBubble: View {
    let message: MessageDTO
    let palette: BriefingPalette

    var body: some View {
        if message.role == "user" {
            userBubble
        } else {
            assistantBubble
        }
    }

    @ViewBuilder private var userBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                eyebrow(label: "USER", time: message.createdAt)
                attachmentChips(alignment: .trailing)
                if !message.plainText.isEmpty {
                    Text(message.plainText)
                        .font(palette.chatBodyFont)
                        .foregroundColor(palette.ink)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(palette.userBubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: 540, alignment: .trailing)
        }
        .accessibilityLabel("Tin nhắn người dùng")
    }

    @ViewBuilder private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 14) {
            Rectangle()
                .fill(palette.rose)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 10) {
                eyebrow(label: "CLAUDE", time: message.createdAt)
                ForEach(ChatFenceParser.segments(of: message.plainText)) { seg in
                    switch seg {
                    case .text(let body):
                        Text(body)
                            .font(palette.chatBodyFont)
                            .foregroundColor(palette.ink)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .code(let lang, let body):
                        ChatCodeBlock(code: body, language: lang, palette: palette)
                    }
                }
                if let tok = tokenLine {
                    Text(tok)
                        .font(.system(size: 10.5))
                        .foregroundColor(palette.ink3)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Tin nhắn từ Claude")
    }

    @ViewBuilder private func eyebrow(label: String, time: Date) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .kerning(1.5)
                .font(palette.chatEyebrowFont)
                .foregroundColor(palette.ink3)
            Text(ChatTimeFormatter.short(time))
                .font(.system(size: 10.5))
                .foregroundColor(palette.ink3)
        }
    }

    @ViewBuilder private func attachmentChips(alignment: HorizontalAlignment) -> some View {
        let atts = message.content.filter { $0.attachmentID != nil }
        if !atts.isEmpty {
            HStack(spacing: 8) {
                ForEach(atts.indices, id: \.self) { i in
                    let a = atts[i]
                    ChatAttachmentThumbnail(
                        attachmentID: a.attachmentID ?? "",
                        mediaType: a.mediaType,
                        palette: palette
                    )
                }
            }
        }
    }

    private var tokenLine: String? {
        guard let inT = message.inputTokens, let outT = message.outputTokens else { return nil }
        if inT == 0 && outT == 0 { return nil }
        return "in \(inT) · out \(outT) token"
    }
}
