import Foundation
import Combine
import SwiftUI

/// Primary @ObservableObject for Chat mode. Owns the conversation list, the
/// active conversation, the message history, and the in-flight streaming
/// state. Views never call CswClient directly — they go through one of the
/// public methods here so all state mutations + refresh sequencing live in
/// a single place.
///
/// Account binding: the store observes AppStore.snapshot.active?.account.id
/// (the account number). When it changes, the store cancels any in-flight
/// stream, clears state, and re-fetches conversations for the new account.
@MainActor
final class ChatStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var conversations: [ConversationDTO] = []
    @Published private(set) var activeConversation: ConversationDTO?
    @Published private(set) var messages: [MessageDTO] = []

    /// Token-by-token assistant text the composer renders while the response
    /// is streaming. nil when no send is in flight.
    @Published private(set) var streamingText: String?

    /// True while a SendMessage stream is open. Composer disables send.
    @Published private(set) var isSending: Bool = false

    /// User-visible error (already redacted of tokens by CswError.redact).
    @Published private(set) var lastError: String?

    /// Model picked when newConversation() runs. Per-conversation model is
    /// captured at create time on the backend — this is just the default.
    @Published var preferredModel: String = "claude-sonnet-4-6"

    // MARK: - Private

    private weak var appStore: AppStore?
    private var accountObservation: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var lastObservedAccountNumber: Int?
    private var typewriter: TypewriterRenderer!

    // MARK: - Wiring

    init() {
        let store = self
        self.typewriter = TypewriterRenderer { [weak store] displayed in
            store?.streamingText = displayed
        }
    }

    /// Bind to AppStore so we react to account switches. Idempotent — calling
    /// again cancels the prior observation Task.
    func bind(to appStore: AppStore) {
        self.appStore = appStore
        accountObservation?.cancel()
        accountObservation = Task { [weak self, weak appStore] in
            guard let appStore else { return }
            for await snapshot in appStore.$snapshot.values {
                guard let self else { return }
                let acctNum = snapshot?.active?.account.number
                if acctNum != self.lastObservedAccountNumber {
                    self.lastObservedAccountNumber = acctNum
                    await self.handleAccountChange()
                }
            }
        }
    }

    private func handleAccountChange() async {
        streamTask?.cancel()
        streamTask = nil
        typewriter.reset()
        streamingText = nil
        isSending = false
        activeConversation = nil
        messages = []
        lastError = nil
        AttachmentPreviewCache.shared.clear()
        await refreshConversations()
    }

    // MARK: - Conversations

    func refreshConversations() async {
        guard let client = appStore?.client else { return }
        do {
            let list = try await client.chatConversationsList()
            self.conversations = list
            if activeConversation == nil, let first = list.first {
                await selectConversation(id: first.id)
            }
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    func selectConversation(id: String) async {
        guard let client = appStore?.client else { return }
        if let existing = activeConversation, existing.id == id { return }
        do {
            let loaded = try await client.chatConversationLoad(id)
            self.activeConversation = loaded.conversation
            self.messages = loaded.messages
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    func newConversation() async {
        guard let client = appStore?.client else { return }
        do {
            let conv = try await client.chatConversationCreate(
                model: preferredModel,
                title: "Đoạn chat mới",
                systemPrompt: nil
            )
            conversations.insert(conv, at: 0)
            activeConversation = conv
            messages = []
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    func renameConversation(id: String, title: String) async {
        guard let client = appStore?.client else { return }
        do {
            try await client.chatConversationRename(id, title: title)
            if let idx = conversations.firstIndex(where: { $0.id == id }) {
                let c = conversations[idx]
                conversations[idx] = ConversationDTO(
                    id: c.id, accountUUID: c.accountUUID, title: title,
                    model: c.model, systemPrompt: c.systemPrompt, archived: c.archived,
                    createdAt: c.createdAt, updatedAt: Date()
                )
            }
            if activeConversation?.id == id {
                activeConversation = conversations.first(where: { $0.id == id })
            }
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Switch the model on the currently-active conversation. Updates the
    /// backend row so subsequent sends use the new model, then patches the
    /// local copy so the picker pill reflects it immediately. Also updates
    /// `preferredModel` so the next new conversation inherits the choice.
    func setActiveConversationModel(_ model: String) async {
        guard let client = appStore?.client else { return }
        guard let conv = activeConversation else {
            preferredModel = model
            return
        }
        if conv.model == model {
            preferredModel = model
            return
        }
        do {
            try await client.chatConversationSetModel(conv.id, model: model)
            preferredModel = model
            let patched = ConversationDTO(
                id: conv.id, accountUUID: conv.accountUUID, title: conv.title,
                model: model, systemPrompt: conv.systemPrompt, archived: conv.archived,
                createdAt: conv.createdAt, updatedAt: Date()
            )
            activeConversation = patched
            if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
                conversations[idx] = patched
            }
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    func deleteConversation(id: String) async {
        guard let client = appStore?.client else { return }
        do {
            try await client.chatConversationDelete(id)
            conversations.removeAll(where: { $0.id == id })
            if activeConversation?.id == id {
                activeConversation = nil
                messages = []
            }
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    // MARK: - Streaming send

    /// Phase-4 Command-Center spawn options. SessionPanel sets these before
    /// calling sendCurrent so the next spawn carries permission-mode +
    /// context-inject. Cleared back to nil after a send so subsequent
    /// chat-tab sends behave normally.
    var nextPermissionMode: String?
    var nextContextInject: ChatStreamReader.ContextInject?

    /// Fire-and-forget. The streamTask owns the lifetime; cancelCurrentSend()
    /// stops it. UI must not call sendCurrent again while isSending is true.
    func sendCurrent(text: String, attachmentIDs: [String] = []) {
        guard !isSending else { return }
        guard let conv = activeConversation else { return }
        guard let client = appStore?.client else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachmentIDs.isEmpty else { return }

        // Optimistic local user bubble — gets replaced by the server-side
        // record next time we reload the conversation.
        let userMsg = MessageDTO.localUser(
            conversationID: conv.id, text: trimmed, attachmentIDs: attachmentIDs
        )
        messages.append(userMsg)
        streamingText = ""
        isSending = true
        lastError = nil

        // Snapshot then clear so subsequent sends from the chat tab are
        // unaffected. The fields are intentionally one-shot.
        let permMode = nextPermissionMode
        let ctxInject = nextContextInject
        nextPermissionMode = nil
        nextContextInject = nil

        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runStream(client: client, conv: conv, text: trimmed,
                                 attachmentIDs: attachmentIDs,
                                 permissionMode: permMode, contextInject: ctxInject)
        }
    }

    private func runStream(
        client: CswClient,
        conv: ConversationDTO,
        text: String,
        attachmentIDs: [String],
        permissionMode: String? = nil,
        contextInject: ChatStreamReader.ContextInject? = nil
    ) async {
        defer { isSending = false }
        let stream = client.chatSend(
            conversationID: conv.id, text: text, attachmentIDs: attachmentIDs,
            permissionMode: permissionMode, contextInject: contextInject
        )
        do {
            for try await event in stream {
                if Task.isCancelled { break }
                await handleStreamEvent(event, conv: conv)
            }
        } catch {
            typewriter.reset()
            streamingText = nil
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    private func handleStreamEvent(_ event: ChatStreamEvent, conv: ConversationDTO) async {
        switch event {
        case .textDelta(let chunk):
            typewriter.append(chunk)
        case .thinkingDelta:
            // Phase 07 will render an extended-thinking bubble; for now drop.
            break
        case .usage:
            break
        case .done(let msgID, _, let inTok, let outTok):
            let finalText = typewriter.flushNow()
            if !finalText.isEmpty {
                let asst = MessageDTO.finalizedAssistant(
                    id: msgID.isEmpty ? UUID().uuidString : "asst-" + msgID,
                    conversationID: conv.id,
                    text: finalText,
                    inputTokens: inTok,
                    outputTokens: outTok
                )
                messages.append(asst)
            }
            typewriter.reset()
            streamingText = nil
        case .error(let code, let message, let retryAfter):
            typewriter.reset()
            streamingText = nil
            let suffix = retryAfter.map { " (retry sau \($0)s)" } ?? ""
            lastError = "[\(code)] \(message)\(suffix)"
        }
    }

    func cancelCurrentSend() {
        streamTask?.cancel()
        typewriter.reset()
        streamingText = nil
        isSending = false
    }

    // MARK: - Attachments

    /// Validates URL extension + size via MediaTypeDetector, reads bytes,
    /// uploads via `csw chat attach`. Returns the AttachmentDTO on success
    /// or sets `lastError` and returns nil on validation / upload failure.
    func attachFile(url: URL) async -> AttachmentDTO? {
        guard let client = appStore?.client else { return nil }
        guard let conv = activeConversation else {
            lastError = "Hãy mở một đoạn chat trước khi đính kèm."
            return nil
        }
        guard let resolved = MediaTypeDetector.detect(url: url) else {
            lastError = "Định dạng không hỗ trợ: \(url.lastPathComponent)"
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let cap = MediaTypeDetector.sizeCap(for: resolved.kind)
            if Int64(data.count) > cap {
                let mb = MediaTypeDetector.sizeCapMB(for: resolved.kind)
                lastError = "File quá lớn (giới hạn \(mb) MB cho \(resolved.kind.rawValue))"
                return nil
            }
            return try await client.chatAttach(
                conversationID: conv.id,
                filename: url.lastPathComponent,
                mediaType: resolved.mediaType,
                data: data
            )
        } catch {
            lastError = CswError.redact(error.localizedDescription)
            return nil
        }
    }

    /// Uploads raw image bytes from a Cmd+V paste action. Caller passes
    /// PNG-encoded bytes; we fabricate a filename so the row carries
    /// something useful for the rail preview.
    func pasteImage(_ data: Data) async -> AttachmentDTO? {
        guard let client = appStore?.client else { return nil }
        guard let conv = activeConversation else {
            lastError = "Hãy mở một đoạn chat trước khi dán ảnh."
            return nil
        }
        if Int64(data.count) > MediaTypeDetector.sizeCap(for: .image) {
            lastError = "Ảnh dán quá lớn (giới hạn 5 MB)."
            return nil
        }
        let filename = "clipboard-\(Int(Date().timeIntervalSince1970)).png"
        do {
            return try await client.chatAttach(
                conversationID: conv.id,
                filename: filename,
                mediaType: "image/png",
                data: data
            )
        } catch {
            lastError = CswError.redact(error.localizedDescription)
            return nil
        }
    }

    /// Returns the decrypted plaintext bytes for an attachment, hitting the
    /// preview cache first. Used by message-bubble thumbnails for history.
    func loadAttachmentBytes(id: String) async -> Data? {
        if let cached = AttachmentPreviewCache.shared.read(id) {
            return cached
        }
        guard let client = appStore?.client else { return nil }
        do {
            let data = try await client.chatAttachmentRead(id: id)
            AttachmentPreviewCache.shared.write(id, data: data)
            return data
        } catch {
            lastError = CswError.redact(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Convenience

    func dismissError() { lastError = nil }
}
