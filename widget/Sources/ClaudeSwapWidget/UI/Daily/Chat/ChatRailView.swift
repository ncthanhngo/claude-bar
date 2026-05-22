import SwiftUI

/// Left rail of the Chat mode: header label + scrollable conversation list +
/// bottom search bar. 320pt wide (set by parent ChatModeBody).
struct ChatRailView: View {
    @EnvironmentObject private var chatStore: ChatStore
    let palette: BriefingPalette
    @State private var query: String = ""
    @State private var renameTargetID: String?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            ChatRailSearchBar(query: $query, palette: palette)
        }
        .background(palette.paper2)
        .sheet(item: Binding(
            get: { renameTargetID.map(RenameTarget.init) },
            set: { renameTargetID = $0?.id }
        )) { tgt in
            renameSheet(targetID: tgt.id)
        }
    }

    @ViewBuilder private var header: some View {
        HStack {
            Text("Chat gần đây")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(2.2)
                .foregroundColor(palette.ink3)
            Spacer()
            Text("\(chatStore.conversations.count)")
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.4)
                .foregroundColor(palette.ink3)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(palette.paper)
                .overlay(Capsule().stroke(palette.line, lineWidth: 1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var list: some View {
        let visible = filtered
        if chatStore.conversations.isEmpty {
            ChatRailEmptyState(palette: palette) {
                Task { await chatStore.newConversation() }
            }
        } else if visible.isEmpty {
            VStack {
                Spacer(minLength: 32)
                Text("Không khớp với \"\(query)\"")
                    .font(.system(size: 12, design: .serif).italic())
                    .foregroundColor(palette.ink3)
                Spacer()
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { conv in
                        ChatRailItem(
                            conversation: conv,
                            isActive: chatStore.activeConversation?.id == conv.id,
                            palette: palette,
                            onSelect: { Task { await chatStore.selectConversation(id: conv.id) } },
                            onDelete: { Task { await chatStore.deleteConversation(id: conv.id) } },
                            onRename: {
                                renameDraft = conv.title
                                renameTargetID = conv.id
                            }
                        )
                    }
                }
            }
        }
    }

    private var filtered: [ConversationDTO] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return chatStore.conversations }
        return chatStore.conversations.filter { conv in
            conv.title.lowercased().contains(q) || conv.model.lowercased().contains(q)
        }
    }

    @ViewBuilder private func renameSheet(targetID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Đổi tên đoạn chat")
                .font(.system(size: 14, weight: .semibold))
            TextField("Tiêu đề mới", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Huỷ") { renameTargetID = nil }
                Button("Lưu") {
                    let id = targetID
                    let title = renameDraft
                    renameTargetID = nil
                    Task { await chatStore.renameConversation(id: id, title: title) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct RenameTarget: Identifiable, Hashable { let id: String }
