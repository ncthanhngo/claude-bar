import Foundation

/// Spawns `csw chat send <conv-id>` with the JSON input piped on stdin and
/// surfaces the line-delimited JSON event stream from stdout as an
/// `AsyncThrowingStream<ChatStreamEvent, Error>`. Cancelling the stream
/// (via Task cancellation) sends SIGINT to the subprocess; the csw side
/// returns exit code 130 which we treat as a clean termination, not an
/// error — the caller already knows it cancelled.
enum ChatStreamReader {
    /// stdin payload shape mirroring the Go CLI's expected JSON.
    /// Optional Phase-4 fields are encoded only when set, so the chat-tab
    /// path stays byte-for-byte identical with the old stdin shape.
    private struct SendInput: Encodable {
        let text: String
        let attachmentIDs: [String]
        let permissionMode: String?
        let contextInject: ContextInject?

        enum CodingKeys: String, CodingKey {
            case text
            case attachmentIDs = "attachment_ids"
            case permissionMode = "permission_mode"
            case contextInject = "context_inject"
        }
    }

    /// Mirror of `contextInjectIn` on the Go side.
    struct ContextInject: Encodable, Equatable {
        let repoPath: String?
        let sshHost: String?
        let claudeAccount: String?
        let briefingFocus: String?

        enum CodingKeys: String, CodingKey {
            case repoPath = "repo_path"
            case sshHost = "ssh_host"
            case claudeAccount = "claude_account"
            case briefingFocus = "briefing_focus"
        }

        var isEmpty: Bool {
            (repoPath ?? "").isEmpty && (sshHost ?? "").isEmpty
                && (claudeAccount ?? "").isEmpty && (briefingFocus ?? "").isEmpty
        }
    }

    /// Starts the subprocess and returns the event stream. Errors bubble as
    /// `CswError.binaryNotFound` / `CswError.nonZeroExit` / decode errors.
    static func send(
        conversationID: String,
        text: String,
        attachmentIDs: [String],
        permissionMode: String? = nil,
        contextInject: ContextInject? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let bin = CswBinary.resolve() else {
                continuation.finish(throwing: CswError.binaryNotFound)
                return
            }

            let task = Process()
            task.executableURL = bin
            task.arguments = ["chat", "send", conversationID]
            // Forward the user's chosen chat-tool tier through an env var so
            // the Go ChatClient can pick the matching `claude -p` flag set
            // without us threading another CLI argument through the chain.
            // UserDefaults reads are MainActor-isolated; the @AppStorage value
            // is captured up-front and the stream itself runs nonisolated.
            var env = ProcessInfo.processInfo.environment
            env["CB_CHAT_TOOL_MODE"] = ChatStreamReader.currentToolMode().rawValue
            task.environment = env

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardInput = stdin
            task.standardOutput = stdout
            task.standardError = stderr

            let decoder = JSONDecoder()
            let splitter = StreamLineSplitter()

            // `readabilityHandler` fires on a background queue. Decode + yield
            // there — the AsyncThrowingStream continuation is Sendable and the
            // consumer is the @MainActor ChatStore which hops back as needed.
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                splitter.feed(data) { line in
                    decode(line: line, decoder: decoder, continuation: continuation)
                }
            }

            task.terminationHandler = { proc in
                // Stop reading; flush any trailing partial line that didn't
                // get a newline (rare but possible if the CLI is killed mid-write).
                stdout.fileHandleForReading.readabilityHandler = nil
                splitter.flush { line in
                    decode(line: line, decoder: decoder, continuation: continuation)
                }
                if proc.terminationStatus == 0 || proc.terminationStatus == 130 {
                    continuation.finish()
                    return
                }
                let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                let msg = String(data: errData, encoding: .utf8) ?? ""
                continuation.finish(throwing: CswError.nonZeroExit(
                    code: proc.terminationStatus,
                    stderr: CswError.redact(msg)
                ))
            }

            continuation.onTermination = { @Sendable _ in
                if task.isRunning {
                    task.interrupt() // SIGINT — Go CLI catches this and exits 130
                }
            }

            do {
                try task.run()
                let payload = try JSONEncoder().encode(SendInput(
                    text: text,
                    attachmentIDs: attachmentIDs,
                    permissionMode: permissionMode,
                    contextInject: contextInject
                ))
                let h = stdin.fileHandleForWriting
                try h.write(contentsOf: payload)
                try h.close()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Reads the currently-selected chat tool mode off UserDefaults directly.
    /// We bypass `AppSettings.shared` (MainActor-isolated) so this can be
    /// called from the nonisolated `send(...)` factory without an actor hop —
    /// the cost is the default fallback if the user never opened the MCP tab.
    private static func currentToolMode() -> ChatToolMode {
        let raw = UserDefaults.standard.string(forKey: "chatToolMode") ?? ChatToolMode.safe.rawValue
        return ChatToolMode(rawValue: raw) ?? .safe
    }

    private static func decode(
        line: String,
        decoder: JSONDecoder,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let ev = try decoder.decode(ChatStreamEvent.self, from: data)
            continuation.yield(ev)
        } catch {
            // Drop unknown / malformed lines — never blow up the stream over
            // a single weird line. The CLI is the source of truth; mismatch
            // means we need a schema bump, not a runtime crash.
            print("[ChatStreamReader] decode skipped: \(error.localizedDescription)")
        }
    }
}
