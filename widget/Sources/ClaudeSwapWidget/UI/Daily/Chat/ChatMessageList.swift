import SwiftUI

/// Scrollable list of past messages + the live streaming bubble at the
/// bottom. Auto-scrolls to bottom on new content. Streaming bubble lives
/// OUTSIDE the LazyVStack so its 30 Hz re-renders don't churn the list.
struct ChatMessageList: View {
    @EnvironmentObject private var chatStore: ChatStore
    let palette: BriefingPalette

    private let bottomAnchorID = "chat-bottom-anchor"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(chatStore.messages) { msg in
                            ChatMessageBubble(message: msg, palette: palette)
                                .id(msg.id)
                        }
                    }
                    ChatStreamingBubble(palette: palette)
                    Color.clear.frame(height: 1).id(bottomAnchorID)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(palette.paper)
            .onChange(of: chatStore.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: chatStore.streamingText) { _, _ in
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: chatStore.activeConversation?.id) { _, _ in
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}
