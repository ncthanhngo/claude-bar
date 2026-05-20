import Foundation

/// Errors surfaced by CswClient.
enum CswError: LocalizedError {
    case binaryNotFound
    case nonZeroExit(code: Int32, stderr: String)
    case decodingFailed(underlying: Error, raw: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "csw binary not found. Set $CSW_BIN or install to /usr/local/bin/csw."
        case .nonZeroExit(let code, let stderr):
            return "csw exited \(code): \(stderr)"
        case .decodingFailed(let err, let raw):
            return "csw JSON decode failed: \(err.localizedDescription)\nRaw: \(raw.prefix(400))"
        }
    }
}

/// Async wrapper around the `csw` Go binary.
actor CswClient {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            if let date = withFractional.date(from: str) { return date }
            if let date = plain.date(from: str) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unparseable ISO8601 date: \(str)"
            ))
        }
        return d
    }()

    func list() async throws -> ListAccountsDTO {
        try await run(["list", "--json"], decode: ListAccountsDTO.self)
    }

    func sessions() async throws -> SessionReportDTO {
        struct Wrap: Codable { let report: SessionReportDTO }
        let w = try await run(["sessions", "--json"], decode: Wrap.self)
        return w.report
    }

    func switchTo(_ num: Int) async throws {
        _ = try await runRaw(["switch", "--json", String(num)])
    }

    func add(nickname: String?) async throws -> AddAccountDTO {
        var args = ["add", "--json"]
        if let n = nickname, !n.isEmpty {
            args.append("--nickname=\(n)")
        }
        return try await run(args, decode: AddAccountDTO.self)
    }

    func rename(_ num: Int, to nickname: String) async throws {
        _ = try await runRaw(["rename", "--json", String(num), nickname])
    }

    func remove(_ num: Int) async throws {
        _ = try await runRaw(["remove", "--json", String(num)])
    }

    func verify() async throws -> VerificationReportDTO {
        try await run(["verify", "--json"], decode: VerificationReportDTO.self)
    }

    func refreshAllTokens() async throws {
        _ = try await runRaw(["refresh-tokens", "--json"])
    }

    // MARK: - Cloud sync

    struct CloudStatusDTO: Codable {
        let exists: Bool
        let path: String
        let pushedAt: Date?
        let sizeKb: Int?
    }

    func cloudStatus() async throws -> CloudStatusDTO {
        try await run(["cloud", "status", "--json"], decode: CloudStatusDTO.self)
    }

    func cloudPush(passphrase: String) async throws {
        try await runWithPassphrase(["cloud", "push", "--json"], passphrase: passphrase)
    }

    func cloudPull(passphrase: String) async throws {
        try await runWithPassphrase(["cloud", "pull", "--json"], passphrase: passphrase)
    }

    func cloudForget() async throws {
        _ = try await runRaw(["cloud", "forget", "--json"])
    }

    // MARK: - Local MCP

    func mcpStatus() async throws -> MCPInstallStatusDTO {
        try await run(["mcp", "status", "--json"], decode: MCPInstallStatusDTO.self)
    }

    func mcpInstall(force: Bool = false) async throws {
        var args = ["mcp", "install"]
        if force { args.append("--force") }
        _ = try await runRaw(args)
    }

    func mcpUninstall() async throws {
        _ = try await runRaw(["mcp", "uninstall"])
    }

    func mcpConnectorsList() async throws -> [MCPAccountSummaryDTO] {
        try await run(["mcp", "connectors", "list", "--json"], decode: [MCPAccountSummaryDTO].self)
    }

    /// Connects a Slack or ClickUp connector by piping the user-pasted token
    /// over stdin. The token never appears in argv / shell history.
    func mcpConnectorConnectToken(
        account: Int,
        service: String,
        token: String,
        displayName: String? = nil
    ) async throws {
        var args = ["mcp", "connectors", "connect",
                    "--account", String(account),
                    "--service", service,
                    "--token", "-"]
        if let dn = displayName, !dn.isEmpty {
            args.append(contentsOf: ["--name", dn])
        }
        try await runWithStdin(args, stdin: token)
    }

    /// Starts the Google Drive OAuth loopback flow inside csw. Blocks until
    /// the user finishes the browser consent step (or 5-min timeout).
    func mcpConnectorConnectGoogle(
        account: Int,
        clientID: String,
        displayName: String? = nil
    ) async throws {
        var args = ["mcp", "connectors", "connect",
                    "--account", String(account),
                    "--service", "gdrive"]
        // Empty clientID means "use the build-time default baked into csw".
        if !clientID.isEmpty {
            args.append(contentsOf: ["--client-id", clientID])
        }
        if let dn = displayName, !dn.isEmpty {
            args.append(contentsOf: ["--name", dn])
        }
        _ = try await runRaw(args)
    }

    func mcpConnectorDisconnect(account: Int, service: String) async throws {
        _ = try await runRaw([
            "mcp", "connectors", "disconnect",
            "--account", String(account),
            "--service", service,
        ])
    }

    private func runWithStdin(_ args: [String], stdin payload: String) async throws {
        guard let bin = CswBinary.resolve() else { throw CswError.binaryNotFound }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.executableURL = bin
            task.arguments = args
            let stdinPipe = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardInput = stdinPipe
            task.standardOutput = stdout
            task.standardError = stderr
            task.terminationHandler = { proc in
                let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let msg = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: CswError.nonZeroExit(code: proc.terminationStatus, stderr: msg))
                }
            }
            do {
                try task.run()
                if let data = payload.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private func runWithPassphrase(_ args: [String], passphrase: String) async throws {
        guard let bin = CswBinary.resolve() else { throw CswError.binaryNotFound }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.executableURL = bin
            task.arguments = args
            let stdin  = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardInput  = stdin
            task.standardOutput = stdout
            task.standardError  = stderr
            task.terminationHandler = { proc in
                let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let msg = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: CswError.nonZeroExit(code: proc.terminationStatus, stderr: msg))
                }
            }
            do {
                try task.run()
                let line = (passphrase + "\n").data(using: .utf8)!
                stdin.fileHandleForWriting.write(line)
                stdin.fileHandleForWriting.closeFile()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private func run<T: Decodable>(_ args: [String], decode: T.Type) async throws -> T {
        let raw = try await runRaw(args)
        do {
            return try decoder.decode(T.self, from: raw)
        } catch {
            let str = String(data: raw, encoding: .utf8) ?? "<binary>"
            throw CswError.decodingFailed(underlying: error, raw: str)
        }
    }

    private func runRaw(_ args: [String]) async throws -> Data {
        guard let bin = CswBinary.resolve() else {
            throw CswError.binaryNotFound
        }
        return try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.executableURL = bin
            task.arguments = args
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardOutput = stdout
            task.standardError = stderr
            task.terminationHandler = { proc in
                let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: outData)
                } else {
                    let msg = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: CswError.nonZeroExit(code: proc.terminationStatus, stderr: msg))
                }
            }
            do {
                try task.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
