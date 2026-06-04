import Foundation

/// Drives the "Trợ lý máy chủ" chat in the Sao lưu tab: the active Claude
/// account converses with the user and proposes shell commands to run on a
/// tracked SSH host (install packages, configure services, inspect state).
///
/// The embedded chat backend streams plain text only — it has no native tool
/// use — so command execution is an app-side agentic loop:
///   1. The assistant emits ONE command inside a ```run fenced block.
///   2. We classify it with the same Go classifier the MCP gate uses.
///   3. Read-only (low risk) commands run straight away; anything that mutates
///      the server waits for the user's confirm in `ServerCommandConfirmSheet`.
///   4. The command output is fed back and the assistant continues, until a
///      turn arrives with no command (it needs input or the job is done).
///
/// Each turn spins a transient conversation (create → send → delete) and
/// replays the whole transcript + command outputs into one prompt, so nothing
/// is persisted to the user's chat history.
@MainActor
final class ServerAgentStore: ObservableObject {

    // MARK: transcript model

    struct Command: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var risk: CswClient.SSHRisk
        var status: Status
        var stdout: String = ""
        var stderr: String = ""
        var exitCode: Int?

        enum Status: Equatable { case pendingConfirm, running, succeeded, failed, declined }
    }

    enum Cell: Identifiable, Equatable {
        case user(id: UUID, text: String)
        case assistant(id: UUID, text: String)
        case command(Command)

        var id: UUID {
            switch self {
            case .user(let id, _), .assistant(let id, _): return id
            case .command(let c): return c.id
            }
        }
    }

    @Published private(set) var cells: [Cell] = []
    @Published var hosts: [CswClient.SSHHostDTO] = []
    @Published var selectedHost: String?
    @Published private(set) var isBusy = false       // assistant streaming or command running
    @Published private(set) var pendingCommandID: UUID?  // awaiting user confirm
    @Published var error: String?

    private let client = CswClient()
    private let model = "claude-sonnet-4-6"
    /// Hard cap on commands auto-chained without the user typing, so a confused
    /// assistant can never run away executing on the server.
    private let maxChain = 20
    private var chainCount = 0

    var canSend: Bool { selectedHost != nil && !isBusy && pendingCommandID == nil }

    // MARK: lifecycle

    func loadHosts() async {
        do {
            hosts = try await client.sshList().sorted { $0.name < $1.name }
            if selectedHost == nil { selectedHost = hosts.first?.name }
        } catch {
            self.error = CswError.redact(error.localizedDescription)
        }
    }

    func reset() {
        cells = []; pendingCommandID = nil; error = nil; chainCount = 0; isBusy = false
    }

    // MARK: user input

    func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, canSend else { return }
        cells.append(.user(id: UUID(), text: q))
        chainCount = 0
        Task { await runAssistantTurn() }
    }

    // MARK: confirm-sheet callbacks

    var pendingCommand: Command? {
        guard let id = pendingCommandID else { return nil }
        return commandValue(id)
    }

    func approvePending() {
        guard let id = pendingCommandID else { return }
        pendingCommandID = nil
        Task { await execute(id) }
    }

    func declinePending() {
        guard let id = pendingCommandID, let idx = index(of: id) else { return }
        update(at: idx) { $0.status = .declined }
        pendingCommandID = nil
        // Stop the chain — the user can type guidance for an alternative.
    }

    // MARK: agentic loop

    private func runAssistantTurn() async {
        guard selectedHost != nil else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }

        let assistantID = UUID()
        cells.append(.assistant(id: assistantID, text: ""))
        var streamed = ""
        do {
            let conv = try await client.chatConversationCreate(
                model: model, title: "Server assistant", systemPrompt: systemPrompt())
            defer { Task { try? await client.chatConversationDelete(conv.id) } }
            for try await ev in client.chatSend(conversationID: conv.id, text: renderPrompt(), attachmentIDs: []) {
                switch ev {
                case .textDelta(let t):
                    streamed += t
                    setAssistant(assistantID, text: ServerAgentParser.visibleText(streamed))
                case .error(_, let message, _):
                    error = message
                default: break
                }
            }
        } catch {
            self.error = CswError.redact(error.localizedDescription)
            return
        }

        // Did the assistant ask to run a command this turn?
        guard let cmd = ServerAgentParser.firstCommand(in: streamed) else { return }

        // Drop an empty assistant bubble (command-only turn) to keep it tidy.
        if ServerAgentParser.visibleText(streamed).isEmpty { removeCell(assistantID) }

        await proposeCommand(cmd)
    }

    private func proposeCommand(_ text: String) async {
        let risk: CswClient.SSHRisk
        do { risk = try await client.sshClassify(command: text) }
        catch { risk = .destructive }   // fail safe: unknown → gate it

        let command = Command(text: text, risk: risk,
                              status: risk.isAutoRunnable ? .running : .pendingConfirm)
        cells.append(.command(command))

        if risk.isAutoRunnable {
            await execute(command.id)
        } else {
            pendingCommandID = command.id   // surfaces the confirm sheet
        }
    }

    private func execute(_ id: UUID) async {
        guard let host = selectedHost, let idx = index(of: id) else { return }
        update(at: idx) { $0.status = .running }
        isBusy = true
        defer { isBusy = false }

        let cmdText = commandValue(id)?.text ?? ""
        do {
            let res = try await client.sshExec(host: host, command: cmdText)
            update(at: idx) {
                $0.stdout = res.stdout
                $0.stderr = res.stderr
                $0.exitCode = res.exitCode
                $0.status = res.exitCode == 0 ? .succeeded : .failed
            }
        } catch {
            update(at: idx) {
                $0.stderr = CswError.redact(error.localizedDescription)
                $0.status = .failed
            }
        }

        // Feed the result back so the assistant can react — bounded so a loop
        // can't run away executing on the server without the user.
        chainCount += 1
        if chainCount >= maxChain {
            cells.append(.assistant(id: UUID(),
                text: "Đã tạm dừng sau \(maxChain) lệnh liên tiếp. Nhập tin nhắn để tiếp tục."))
            chainCount = 0
            return
        }
        await runAssistantTurn()
    }

    // MARK: prompt rendering

    private func systemPrompt() -> String {
        let host = selectedHost ?? "?"
        let info = hosts.first { $0.name == host }
        var meta = "host \"\(host)\""
        if let h = info?.hostName { meta += " (\(h))" }
        if let u = info?.user { meta += ", user \(u)" }
        return """
        Bạn là trợ lý vận hành máy chủ trong app AI Bar. Bạn giúp người dùng cài đặt, \
        cấu hình và kiểm tra một máy chủ Linux từ xa qua SSH (\(meta)).

        QUY TẮC CHẠY LỆNH:
        - Khi cần chạy một lệnh shell trên máy chủ, in ra ĐÚNG MỘT khối mã có ngôn ngữ là \
        `run`, chứa duy nhất một lệnh trên một dòng. Ví dụ:
        ```run
        apt-get install -y nginx
        ```
        - Mỗi lượt chỉ đề xuất một lệnh. Sau khi chạy, tôi sẽ gửi lại kết quả \
        (mã thoát + stdout/stderr) để bạn quyết định bước tiếp theo.
        - KHÔNG dùng dấu nối lệnh phức tạp khi không cần (`;`, `&&`, `|`); chia nhỏ thành \
        nhiều bước để dễ kiểm soát. Lệnh nguy hiểm cần người dùng xác nhận thủ công.
        - Khi hoàn thành mục tiêu, hoặc khi cần người dùng cung cấp thêm thông tin, hãy \
        trả lời bình thường mà KHÔNG kèm khối ```run.
        - Trả lời ngắn gọn bằng tiếng Việt.
        """
    }

    /// Replays the transcript so a fresh conversation has full context, ending
    /// with a cue for the next assistant turn.
    private func renderPrompt() -> String {
        var parts: [String] = []
        for cell in cells {
            switch cell {
            case .user(_, let t):
                parts.append("## Người dùng\n\(t)")
            case .assistant(_, let t) where !t.isEmpty:
                parts.append("## Trợ lý\n\(t)")
            case .assistant:
                break
            case .command(let c):
                parts.append(renderCommand(c))
            }
        }
        parts.append("## Trợ lý\n")
        return parts.joined(separator: "\n\n")
    }

    private func renderCommand(_ c: Command) -> String {
        switch c.status {
        case .pendingConfirm, .running:
            return "## Lệnh đã đề xuất\n`\(c.text)`"
        case .declined:
            return "## Lệnh `\(c.text)`\nNgười dùng đã từ chối chạy lệnh này."
        case .succeeded, .failed:
            let out = [c.stdout, c.stderr.isEmpty ? "" : "[stderr] " + c.stderr]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            let trimmed = String(out.prefix(8000))
            return """
            ## Kết quả lệnh `\(c.text)`
            Mã thoát: \(c.exitCode ?? -1)
            ```
            \(trimmed.isEmpty ? "(không có output)" : trimmed)
            ```
            """
        }
    }

    // MARK: cell mutation helpers

    private func setAssistant(_ id: UUID, text: String) {
        guard let idx = cells.firstIndex(where: { $0.id == id }) else { return }
        cells[idx] = .assistant(id: id, text: text)
    }

    private func removeCell(_ id: UUID) {
        cells.removeAll { $0.id == id }
    }

    private func index(of commandID: UUID) -> Int? {
        cells.firstIndex { if case .command(let c) = $0 { return c.id == commandID }; return false }
    }

    private func commandValue(_ id: UUID) -> Command? {
        for cell in cells { if case .command(let c) = cell, c.id == id { return c } }
        return nil
    }

    private func update(at idx: Int, _ mutate: (inout Command) -> Void) {
        guard case .command(var c) = cells[idx] else { return }
        mutate(&c)
        cells[idx] = .command(c)
    }
}
