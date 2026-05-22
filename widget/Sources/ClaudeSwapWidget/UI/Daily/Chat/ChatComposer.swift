import SwiftUI
import AppKit

/// Sticky-bottom raised card with textarea, attachment row, model picker,
/// and Send button. ⌘↩ sends; plain ↩ inserts newline (default TextField
/// behavior). Files dropped onto the composer get encrypted + persisted
/// via chatStore.attachFile.
struct ChatComposer: View {
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var appStore: AppStore
    let palette: BriefingPalette

    @Binding var draft: String
    @Binding var pendingAttachments: [AttachmentDTO]
    @FocusState private var focused: Bool
    @State private var pendingQuotaConfirm: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            ChatErrorBanner(palette: palette, onRetry: retryLastSend)
            card
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .padding(.top, 4)
        .confirmationDialog(
            "Quota 5h đang ở \(currentQuotaPctText). Có thể trigger auto-swap. Vẫn gửi?",
            isPresented: $pendingQuotaConfirm,
            titleVisibility: .visible
        ) {
            Button("Gửi đi", role: .destructive) { reallySend() }
            Button("Huỷ", role: .cancel) {}
        }
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: 8) {
            ChatComposerAttachments(items: $pendingAttachments, palette: palette)
            textArea
            actionsRow
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(palette.raisedSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 18).stroke(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: palette.cardShadow, radius: 12, x: 0, y: 3)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .onDrop(of: ["public.file-url"], isTargeted: nil, perform: handleDrop(providers:))
    }

    @ViewBuilder private var textArea: some View {
        ChatTextEditor(
            text: $draft,
            palette: palette,
            placeholder: "Hỏi gì đó với Claude…",
            onSend: { handleReturn() }
        )
        .frame(minHeight: 84, maxHeight: 220)
        .overlay(alignment: .topLeading) {
            if draft.isEmpty {
                Text("Hỏi gì đó với Claude…")
                    .font(.system(size: 14.5, design: .serif).italic())
                    .foregroundColor(palette.ink3)
                    .padding(.top, 8)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Plain ↩ in the textarea routes here. Skip when nothing to send / a
    /// stream is in flight so we don't double-fire while the user is just
    /// waiting for tokens.
    private func handleReturn() {
        guard !chatStore.isSending else { return }
        guard !draft.isEmpty || !pendingAttachments.isEmpty else { return }
        sendNow()
    }

    @ViewBuilder private var actionsRow: some View {
        HStack(alignment: .center, spacing: 10) {
            attachButton
            ChatModelPicker(palette: palette)
            Spacer()
            Text("↩ gửi · ⇧↩ xuống dòng")
                .font(.system(size: 10.5))
                .foregroundColor(palette.ink3)
            sendButton
        }
    }

    @ViewBuilder private var attachButton: some View {
        HStack(spacing: 4) {
            Button(action: pickFile) {
                Image(systemName: "paperclip")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(palette.ink2)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Đính kèm ảnh / PDF / text (kéo-thả cũng được)")

            Button(action: pasteFromClipboard) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(palette.ink2)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Dán ảnh từ clipboard (⌘⇧V)")
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
    }

    @ViewBuilder private var sendButton: some View {
        Button(action: sendNow) {
            HStack(spacing: 6) {
                Text(chatStore.isSending ? "Đang gửi…" : "Gửi")
                    .font(.system(size: 13, weight: .semibold))
                Text("↩")
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
    }

    // MARK: - Actions

    private func sendNow() {
        // Guard rail: if 5h quota >= 90% the next send may trip auto-swap
        // mid-conversation. Ask user to confirm before firing.
        if let pct = appStore.snapshot?.active?.usage?.fiveHour?.percentInt, pct >= 90 {
            pendingQuotaConfirm = true
            return
        }
        reallySend()
    }

    private func reallySend() {
        let attIDs = pendingAttachments.map(\.id)
        let text = draft
        chatStore.sendCurrent(text: text, attachmentIDs: attIDs)
        draft = ""
        pendingAttachments = []
    }

    private var currentQuotaPctText: String {
        guard let pct = appStore.snapshot?.active?.usage?.fiveHour?.percentInt else { return "≥ 90%" }
        return "\(pct)%"
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

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        // Prefer file URL paste (matches what Finder copies); fall back to
        // raw image data (screenshot paste).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            Task { await uploadAttachment(url: first) }
            return
        }
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            Task {
                if let att = await chatStore.pasteImage(png) {
                    await MainActor.run { pendingAttachments.append(att) }
                }
            }
            return
        }
        chatStore.dismissError() // no-op if nil; harmless reset
    }
}
