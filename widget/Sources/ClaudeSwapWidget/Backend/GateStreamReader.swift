import Foundation

/// Spawns `csw gate proxy` and bridges its stdout/stdin to a Swift event
/// stream + a send-decision API. The subprocess lives for the duration of
/// the widget process; when the widget exits, the subprocess is SIGINT'd
/// and the UDS connection closes cleanly.
final class GateStreamReader: @unchecked Sendable {
    /// Emitted to the coordinator when a new prompt arrives.
    enum Event {
        case hello
        case prompt(GatePromptDTO)
    }

    private let task: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe
    private let queue = DispatchQueue(label: "claude-bar.gate-stream.write")

    private(set) var isRunning: Bool = false

    init?(yield: @escaping @Sendable (Event) -> Void,
          onTermination: @escaping @Sendable (Int32, String) -> Void) {
        guard let bin = CswBinary.resolve() else { return nil }
        self.task = Process()
        self.stdin = Pipe()
        self.stdout = Pipe()
        self.stderr = Pipe()
        task.executableURL = bin
        task.arguments = ["gate", "proxy"]
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        let decoder = JSONDecoder()
        // Go's encoding/json emits time.Time as RFC3339Nano
        // (e.g. "2026-05-27T16:00:00.123456789Z"). Swift's default
        // .deferredToDate strategy expects Double seconds since 2001 and
        // throws on a string, which silently drops every gate prompt
        // envelope (only `hello` decodes — no date field). Use a custom
        // strategy that accepts RFC3339 with or without fractional seconds.
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let s = try container.decode(String.self)
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFrac.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized RFC3339 date: \(s)"
            )
        }
        let splitter = StreamLineSplitter()
        let inputPipe = stdin
        let writeQueue = queue
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            splitter.feed(data) { line in
                guard let raw = line.data(using: .utf8) else { return }
                do {
                    let env = try decoder.decode(GateInboundEnvelope.self, from: raw)
                    switch env.kind {
                    case "hello":
                        DiagnosticsLogger.shared.log(.info, subsystem: "gate", "ipc hello — proxy connected")
                        Self.writeReady(stdin: inputPipe, queue: writeQueue)
                        yield(.hello)
                    case "prompt":
                        if let p = env.prompt {
                            DiagnosticsLogger.shared.log(.info, subsystem: "gate", "prompt \(p.tool) nonce=\(p.nonce.prefix(8))…")
                            yield(.prompt(p))
                        }
                    default: break
                    }
                } catch {
                    DiagnosticsLogger.shared.log(.warning, subsystem: "gate", "envelope decode failed: \(error.localizedDescription) — line: \(line.prefix(200))")
                }
            }
        }
        task.terminationHandler = { [weak self] proc in
            self?.isRunning = false
            self?.stdout.fileHandleForReading.readabilityHandler = nil
            let errData: Data = (try? self?.stderr.fileHandleForReading.readToEnd()) ?? nil ?? Data()
            let msg = String(data: errData, encoding: .utf8) ?? ""
            onTermination(proc.terminationStatus, CswError.redact(msg))
        }
    }

    /// Starts the subprocess. Safe to call once; subsequent calls are no-ops.
    func start() throws {
        if isRunning { return }
        try task.run()
        isRunning = true
    }

    /// Sends SIGINT and waits up to 1s for the subprocess to exit.
    func stop() {
        if task.isRunning {
            task.interrupt()
        }
    }

    /// Writes one decision envelope on stdin. Safe to call from any queue;
    /// writes are serialised on an internal queue.
    func respond(nonce: String, decision: GateDecision) {
        let env = GateDecisionEnvelope(kind: "respond", nonce: nonce, decision: decision.rawValue)
        Self.writeEnvelope(env, stdin: stdin, queue: queue)
    }

    private static func writeReady(stdin: Pipe, queue: DispatchQueue) {
        writeEnvelope(GateReadyEnvelope(kind: "ready"), stdin: stdin, queue: queue)
    }

    private static func writeEnvelope<T: Encodable>(_ env: T, stdin: Pipe, queue: DispatchQueue) {
        guard let data = try? JSONEncoder().encode(env) else { return }
        queue.async {
            var line = data
            line.append(0x0A) // newline terminator
            try? stdin.fileHandleForWriting.write(contentsOf: line)
        }
    }
}

/// Decision values the widget can send. Mirror of `mcp.Decision` strings.
enum GateDecision: String {
    case approved
    case cancelled
    case timeout
}
