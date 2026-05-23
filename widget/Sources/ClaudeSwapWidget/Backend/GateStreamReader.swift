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
        let splitter = StreamLineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            splitter.feed(data) { line in
                guard let raw = line.data(using: .utf8) else { return }
                guard let env = try? decoder.decode(GateInboundEnvelope.self, from: raw) else { return }
                switch env.kind {
                case "hello": yield(.hello)
                case "prompt":
                    if let p = env.prompt { yield(.prompt(p)) }
                default: break
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
        queue.async { [stdin] in
            guard let data = try? JSONEncoder().encode(env) else { return }
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
