import SwiftUI
import AppKit

/// Sticky-bottom raised card with textarea, attachment row, model picker,
/// and Send button. ⌘↩ sends; plain ↩ inserts newline (default TextField
/// behavior). Files dropped onto the composer get encrypted + persisted
/// via chatStore.attachFile.
struct ChatComposer: View {
    @EnvironmentObject private var chatStore: ChatStore
    let palette: BriefingPalette

    @Binding var draft: String
    @Binding var pendingAttachments: [AttachmentDTO]
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            ChatErrorBanner(palette: palette, onRetry: retryLastSend)
            card
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .padding(.top, 4)
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: 10) {
            ChatComposerAttachments(items: $pendingAttachments, palette: palette)
            textArea
            actionsRow
        }
        .padding(14)
        .background(palette.raisedSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: palette.cardShadow, radius: 8, x: 0, y: 2)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .onDrop(of: ["public.file-url"], isTargeted: nil, perform: handleDrop(providers:))
    }

    @ViewBuilder private var textArea: some View {
        TextEditor(text: $draft)
            .font(.system(size: 14.5))
            .foregroundColor(palette.ink)
            .scrollContentBackground(.hidden)
            .background(palette.raisedSurface)
            .focused($focused)
            .frame(minHeight: 60, maxHeight: 200)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Hỏi gì đó với Claude…")
                        .font(.system(size: 14.5, design: .serif).italic())
                        .foregroundColor(palette.ink3)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private var actionsRow: some View {
        HStack(alignment: .center, spacing: 10) {
            attachButton
            ChatModelPicker(palette: palette)
            Spacer()
            Text("⌘↩ gửi · ↩ xuống dòng")
                .font(.system(size: 10.5))
                .foregroundColor(palette.ink3)
            sendButton
        }
        .padding(.top, 6)
        .overlay(Divider().background(palette.line), alignment: .top)
    }

    @ViewBuilder private var attachButton: some View {
        Button(action: pickFile) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.ink2)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(palette.paper2.opacity(0.0001))
        .help("Đính kèm ảnh / PDF / text")
    }

    @ViewBuilder private var sendButton: some View {
        Button(action: sendNow) {
            HStack(spacing: 6) {
                Text(chatStore.isSending ? "Đang gửi…" : "Gửi")
                    .font(.system(size: 13, weight: .semibold))
                Text("⌘↩")
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .foregroundColor(palette.paper)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(palette.coral))
        .disabled(chatStore.isSending || (draft.isEmpty && pendingAttachments.isEmpty))
        .keyboardShortcut(.return, modifiers: [.command])
    }

    // MARK: - Actions

    private func sendNow() {
        let attIDs = pendingAttachments.map(\.id)
        let text = draft
        chatStore.sendCurrent(text: text, attachmentIDs: attIDs)
        draft = ""
        pendingAttachments = []
    }

    private func retryLastSend() {
        guard let lastUser = chatStore.messages.last(where: { $0.role == "user" }) else { return }
        chatStore.dismissError()
        let attIDs = lastUser.content.compactMap(\.attachmentID)
        chatStore.sendCurrent(text: lastUser.plainText, attachmentIDs: attIDs)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [] // any
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await uploadAttachment(url: url) }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { await uploadAttachment(url: url) }
        }
        return true
    }

    @MainActor
    private func uploadAttachment(url: URL) async {
        if let att = await chatStore.attachFile(url: url) {
            pendingAttachments.append(att)
        }
    }
}
