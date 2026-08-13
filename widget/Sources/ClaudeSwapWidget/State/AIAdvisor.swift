import Foundation

/// Provider-agnostic, multi-turn AI advisor for the Tools tabs. Today it talks
/// to the active Claude account (the app's only AI provider); when Codex lands
/// it routes to whichever provider is active — callers read `providerLabel`.
///
/// Multi-turn without polluting chat history: each turn spins a transient
/// conversation (create → send → delete) and replays the data context + prior
/// Q&A into a single prompt, so follow-up questions keep full context while
/// nothing is persisted.
@MainActor
final class AIAdvisor: ObservableObject {
    enum Provider { case claude /* future: case codex */ }
    static var activeProvider: Provider { .claude }
    static var providerLabel: String {
        switch activeProvider { case .claude: return "Claude" }
    }

    enum Role { case user, assistant }
    struct Msg: Identifiable { let id = UUID(); let role: Role; var text: String }

    @Published private(set) var messages: [Msg] = []
    @Published private(set) var isThinking = false
    @Published var error: String?

    private var system = ""
    private var context = ""
    private let client = CswClient()
    private let model = "claude-sonnet-4-6"

    /// Set the steering prompt + data context once, on a fresh chat.
    func configure(system: String, context: String) {
        guard messages.isEmpty else { return }
        self.system = system
        self.context = context
    }

    func reset() { messages = []; error = nil }

    func send(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking else { return }
        messages.append(Msg(role: .user, text: q))
        let assistantIdx = messages.count
        messages.append(Msg(role: .assistant, text: ""))
        isThinking = true
        error = nil
        defer { isThinking = false }
        do {
            let conv = try await client.chatConversationCreate(
                model: model, title: "Tools advisor", systemPrompt: system)
            defer { Task { try? await client.chatConversationDelete(conv.id) } }
            let prompt = renderForAI()
            for try await ev in client.chatSend(conversationID: conv.id, text: prompt, attachmentIDs: []) {
                switch ev {
                case .textDelta(let t): messages[assistantIdx].text += t
                case .error(_, let message, _): error = message
                default: break
                }
            }
        } catch {
            self.error = CswError.redact(error.localizedDescription)
        }
    }

    /// Data context + the visible Q&A so far, ending with a cue for the next
    /// assistant turn. Lets a brand-new conversation answer with full context.
    private func renderForAI() -> String {
        var parts: [String] = []
        if !context.isEmpty { parts.append(context) }
        for m in messages where !m.text.isEmpty {
            parts.append(m.role == .user ? "## Người dùng\n\(m.text)" : "## Trợ lý\n\(m.text)")
        }
        parts.append("## Trợ lý\n")
        return parts.joined(separator: "\n\n")
    }
}
