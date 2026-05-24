import SwiftUI

/// Sticky Claude-session pane that lives on the right side of the Command
/// Center body. Reuses the existing `ChatStore` so a single conversation
/// powers both the dedicated Chat tab and this embedded panel — no extra
/// backend wiring needed for v1.
///
/// Phase-4 plan extras (permission-mode toggle, queue depth surface,
/// context-inject preview) are layered on once the dedicated
/// `StreamCommandCenter` send path gets exposed through ChatStore. The
/// session panel as shipped is a usable subset that exercises the full
/// chat-tool tier + write-gate cycle end-to-end.
struct SessionPanel: View {
    @EnvironmentObject var chatStore: ChatStore
    @ObservedObject private var settings = AppSettings.shared
    @State private var draft = ""
    @State private var permissionMode: String = "plan"
    @State private var linkedRepoPath: String = ""
    @State private var briefingFocus: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().opacity(0.4)
            transcript
            Divider().opacity(0.4)
            composer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundColor(.accentColor)
            Text("Claude session")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if chatStore.isSending {
                ProgressView().controlSize(.small)
                Button("Cancel") { chatStore.cancelCurrentSend() }
                    .controlSize(.small)
            }
            modeChip
        }
    }

    private var modeChip: some View {
        HStack(spacing: 4) {
            Menu {
                Button("plan (read-only proposals)") { permissionMode = "plan" }
                Button("acceptEdits (auto-confirm safe edits)") { permissionMode = "acceptEdits" }
                Button("bypassPermissions (danger)") { permissionMode = "bypassPermissions" }
            } label: {
                Text(permissionMode.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.18)))
                    .foregroundColor(.purple)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Text(settings.chatToolMode.rawValue.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(modeColor.opacity(0.18)))
                .foregroundColor(modeColor)
        }
    }
    private var modeColor: Color {
        switch settings.chatToolMode {
        case .off: return .secondary
        case .safe: return .green
        case .full: return .orange
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chatStore.messages.isEmpty && chatStore.streamingText == nil {
                        emptyState
                    }
                    ForEach(chatStore.messages) { msg in
                        SessionTurnView(message: msg)
                            .id(msg.id)
                    }
                    if let s = chatStore.streamingText, !s.isEmpty {
                        SessionStreamingTurnView(text: s)
                            .id("__streaming__")
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: chatStore.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("__streaming__", anchor: .bottom) }
            }
            .onChange(of: chatStore.streamingText) { _, _ in
                proxy.scrollTo("__streaming__", anchor: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sẵn sàng nhận lệnh.")
                .font(.system(size: 13, weight: .semibold))
            Text("Mọi tool call qua write-gate trước khi chạy. Ấn ⌘L để focus.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.top, 4)
                TextEditor(text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 30, maxHeight: 80)
                    .focused($inputFocused)
            }
            HStack {
                Text("⌘L focus  ·  ⌘↩ send  ·  ⌘. cancel")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatStore.isSending)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Stamp the next spawn with Phase-4 options. ChatStore clears them
        // back to nil after the send so a follow-on chat-tab send stays
        // permission-less + un-injected.
        chatStore.nextPermissionMode = permissionMode
        let inject = ChatStreamReader.ContextInject(
            repoPath: linkedRepoPath.isEmpty ? nil : linkedRepoPath,
            sshHost: nil,
            claudeAccount: nil,
            briefingFocus: briefingFocus.isEmpty ? nil : briefingFocus
        )
        chatStore.nextContextInject = inject.isEmpty ? nil : inject
        chatStore.sendCurrent(text: text)
        draft = ""
    }
}

/// One assistant or user turn rendered compactly for the session panel.
struct SessionTurnView: View {
    let message: MessageDTO

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: roleIcon)
                .foregroundColor(roleColor)
                .font(.system(size: 10, weight: .heavy))
                .frame(width: 14, alignment: .leading)
            Text(displayText)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(message.role == "user" ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }

    private var roleIcon: String {
        message.role == "user" ? "person.crop.circle" : "sparkles"
    }
    private var roleColor: Color {
        message.role == "user" ? .accentColor : .secondary
    }

    /// Flattens the content blocks into a single string. Tool-use blocks
    /// render as `→ tool_name` so they stay visible without dumping JSON.
    private var displayText: String {
        var out: [String] = []
        for block in message.content {
            switch block.kind {
            case "text":
                if let t = block.text, !t.isEmpty { out.append(t) }
            case "thinking":
                if let t = block.text, !t.isEmpty { out.append("💭 " + t) }
            case "tool_use":
                out.append("→ " + (block.text ?? "tool_use"))
            case "tool_result":
                out.append("← " + (block.text?.prefix(120).description ?? ""))
            default:
                break
            }
        }
        return out.joined(separator: "\n")
    }
}

/// Live-streaming partial assistant turn.
struct SessionStreamingTurnView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundColor(.secondary)
                .font(.system(size: 10, weight: .heavy))
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}
