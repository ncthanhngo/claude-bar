import SwiftUI

/// Title + meta + token chip strip above the message list. Title is editable
/// inline via double-click (commits on Enter / blur). Token chip reads
/// `appStore.snapshot.active?.usage?.fiveHour?.percentInt` and colours by
/// quota tier.
struct ChatThreadHeader: View {
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var appStore: AppStore
    let palette: BriefingPalette

    @State private var editing: Bool = false
    @State private var draftTitle: String = ""

    var body: some View {
        if let conv = chatStore.activeConversation {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    titleField(for: conv)
                    metaLine(for: conv)
                }
                Spacer(minLength: 12)
                tokenChip
            }
            .padding(.horizontal, 36)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .overlay(Divider().background(palette.line), alignment: .bottom)
            .background(palette.paper)
        }
    }

    @ViewBuilder private func titleField(for conv: ConversationDTO) -> some View {
        if editing {
            TextField("Tiêu đề", text: $draftTitle)
                .font(.system(size: 22, design: .serif).italic())
                .foregroundColor(palette.ink)
                .textFieldStyle(.plain)
                .onSubmit { commitTitle(conv.id) }
        } else {
            Text(displayTitle(conv))
                .font(.system(size: 22, design: .serif).italic())
                .foregroundColor(palette.ink)
                .onTapGesture(count: 2) {
                    draftTitle = conv.title
                    editing = true
                }
                .help("Bấm hai lần để đổi tên")
        }
    }

    @ViewBuilder private func metaLine(for conv: ConversationDTO) -> some View {
        HStack(spacing: 10) {
            Text(conv.model)
            Text("·").foregroundColor(palette.line2)
            Text("\(chatStore.messages.count) lượt")
            if chatStore.isSending {
                Text("·").foregroundColor(palette.line2)
                Text("đang gõ…").foregroundColor(palette.coral)
            }
        }
        .font(.system(size: 11.5))
        .foregroundColor(palette.ink3)
    }

    @ViewBuilder private var tokenChip: some View {
        let pct = appStore.snapshot?.active?.usage?.fiveHour?.percentInt
        HStack(spacing: 7) {
            Circle().fill(quotaColor(pct)).frame(width: 7, height: 7)
            Text("5h:")
                .font(.system(size: 11))
                .foregroundColor(palette.ink2)
            Text(pct.map { "\($0)%" } ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.ink)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(palette.paper2)
        .overlay(Capsule().stroke(palette.line2, lineWidth: 1))
        .clipShape(Capsule())
    }

    private func displayTitle(_ conv: ConversationDTO) -> String {
        conv.title.isEmpty ? "Đoạn chat mới" : conv.title
    }

    private func commitTitle(_ id: String) {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard !title.isEmpty else { return }
        Task { await chatStore.renameConversation(id: id, title: title) }
    }

    private func quotaColor(_ pct: Int?) -> Color {
        guard let pct else { return palette.line2 }
        if pct >= 80 { return palette.quotaCoralColor }
        if pct >= 50 { return palette.quotaGoldColor }
        return palette.quotaSageColor
    }
}
