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
    private var deltaBatcher: DeltaBatcher!

    // MARK: - Wiring

    init() {
        // DeltaBatcher captures `self` weakly via the closure; safe.
        let store = self
        self.deltaBatcher = DeltaBatcher(interval: 0.033) { [weak store] chunk in
            guard let store else { return }
            store.streamingText = (store.streamingText ?? "") + chunk
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
        deltaBatcher.reset()
        streamingText = nil
        isSending = false
        activeConversation = nil
        messages = []
        lastError = nil
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

        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runStream(client: client, conv: conv, text: trimmed, attachmentIDs: attachmentIDs)
        }
    }

    private func runStream(
        client: CswClient,
        conv: ConversationDTO,
        text: String,
        attachmentIDs: [String]
    ) async {
        defer { isSending = false }
        let stream = client.chatSend(
            conversationID: conv.id, text: text, attachmentIDs: attachmentIDs
        )
        do {
            for try await event in stream {
                if Task.isCancelled { break }
                await handleStreamEvent(event, conv: conv)
            }
            deltaBatcher.flush()
        } catch {
            deltaBatcher.reset()
            streamingText = nil
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    private func handleStreamEvent(_ event: ChatStreamEvent, conv: ConversationDTO) async {
        switch event {
        case .textDelta(let chunk):
            deltaBatcher.append(chunk)
        case .thinkingDelta:
            // Phase 07 will render an extended-thinking bubble; for now drop.
            break
        case .usage:
            break
        case .done(let msgID, _, let inTok, let outTok):
            deltaBatcher.flush()
            let finalText = streamingText ?? ""
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
            streamingText = nil
        case .error(let code, let message, let retryAfter):
            deltaBatcher.reset()
            streamingText = nil
            let suffix = retryAfter.map { " (retry sau \($0)s)" } ?? ""
            lastError = "[\(code)] \(message)\(suffix)"
        }
    }

    func cancelCurrentSend() {
        streamTask?.cancel()
        deltaBatcher.reset()
        streamingText = nil
        isSending = false
    }

    // MARK: - Attachments

    /// Reads file bytes from `url` and uploads via `csw chat attach`. Returns
    /// the AttachmentDTO so the composer can stash the id for the next send.
    func attachFile(url: URL) async -> AttachmentDTO? {
        guard let client = appStore?.client else { return nil }
        guard let conv = activeConversation else {
            lastError = "Hãy mở một đoạn chat trước khi đính kèm."
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let mediaType = mediaTypeForExtension(url.pathExtension)
            return try await client.chatAttach(
                conversationID: conv.id,
                filename: url.lastPathComponent,
                mediaType: mediaType,
                data: data
            )
        } catch {
            lastError = CswError.redact(error.localizedDescription)
            return nil
        }
    }

    private func mediaTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf":  return "application/pdf"
        case "md", "markdown": return "text/markdown"
        case "txt":  return "text/plain"
        case "json": return "application/json"
        default:     return "application/octet-stream"
        }
    }

    // MARK: - Convenience

    func dismissError() { lastError = nil }
}
