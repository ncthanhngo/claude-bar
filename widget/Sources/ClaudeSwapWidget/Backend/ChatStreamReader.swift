import Foundation

/// Spawns `csw chat send <conv-id>` with the JSON input piped on stdin and
/// surfaces the line-delimited JSON event stream from stdout as an
/// `AsyncThrowingStream<ChatStreamEvent, Error>`. Cancelling the stream
/// (via Task cancellation) sends SIGINT to the subprocess; the csw side
/// returns exit code 130 which we treat as a clean termination, not an
/// error — the caller already knows it cancelled.
enum ChatStreamReader {
    /// stdin payload shape mirroring the Go CLI's expected JSON.
    private struct SendInput: Encodable {
        let text: String
        let attachmentIDs: [String]

        enum CodingKeys: String, CodingKey {
            case text
            case attachmentIDs = "attachment_ids"
        }
    }

    /// Starts the subprocess and returns the event stream. Errors bubble as
    /// `CswError.binaryNotFound` / `CswError.nonZeroExit` / decode errors.
    static func send(
        conversationID: String,
        text: String,
        attachmentIDs: [String]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let bin = CswBinary.resolve() else {
                continuation.finish(throwing: CswError.binaryNotFound)
                return
            }

            let task = Process()
            task.executableURL = bin
            task.arguments = ["chat", "send", conversationID]

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
                    text: text, attachmentIDs: attachmentIDs
                ))
                let h = stdin.fileHandleForWriting
                try h.write(contentsOf: payload)
                try h.close()
            } catch {
                continuation.finish(throwing: error)
            }
        }
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
