import SwiftUI

/// Right column of Chat mode: header + scrollable list + composer. Falls
/// back to a "select a conversation" pane when none is active.
struct ChatThreadView: View {
    @EnvironmentObject private var chatStore: ChatStore
    let palette: BriefingPalette

    @State private var draft: String = ""
    @State private var pendingAttachments: [AttachmentDTO] = []

    var body: some View {
        VStack(spacing: 0) {
            if chatStore.activeConversation == nil {
                placeholder
            } else if chatStore.messages.isEmpty {
                ChatThreadHeader(palette: palette)
                ChatEmptyThreadView(palette: palette) { suggestion in
                    draft = suggestion
                }
                .background(palette.paper)
                composer
            } else {
                ChatThreadHeader(palette: palette)
                ChatMessageList(palette: palette)
                composer
            }
        }
        .background(palette.paper)
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Chọn một đoạn chat ở cột bên trái")
                .font(.system(size: 18, design: .serif).italic())
                .foregroundColor(palette.ink2)
            Text("hoặc bấm \"Đoạn chat mới\" để bắt đầu.")
                .font(.system(size: 12.5))
                .foregroundColor(palette.ink3)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var composer: some View {
        ChatComposer(palette: palette, draft: $draft, pendingAttachments: $pendingAttachments)
    }
}
