import Foundation

/// Errors surfaced by CswClient.
enum CswError: LocalizedError {
    case binaryNotFound
    case nonZeroExit(code: Int32, stderr: String)
    case decodingFailed(underlying: Error, raw: String)

    /// Strip token-shaped strings before surfacing output in the UI.
    static func redact(_ s: String) -> String {
        // JWT (eyJ…)
        var out = s.replacingOccurrences(of: #"eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#,
                                         with: "<redacted>", options: .regularExpression)
        // 32+ char hex / base64 tokens
        out = out.replacingOccurrences(of: #"[A-Za-z0-9+/=_\-]{32,}"#,
                                       with: "<redacted>", options: .regularExpression)
        return out
    }

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "csw binary not found. Set $CSW_BIN or install to /usr/local/bin/csw."
        case .nonZeroExit(let code, let stderr):
            return "csw exited \(code): \(stderr)"
        case .decodingFailed(let err, let raw):
            return "csw JSON decode failed: \(err.localizedDescription)\nRaw: \(CswError.redact(raw).prefix(200))"
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

    /// Snapshot the active account's live Keychain creds into its backup slot.
    /// Call before any flow that overwrites the live slot outside claude-bar
    /// (notably `claude /login`) so the rotated refresh token is preserved.
    func snapshotActiveLive() async throws {
        _ = try await runRaw(["snapshot-active", "--json"])
    }

    // MARK: - Cloud sync

    struct CloudStatusDTO: Codable {
        let exists: Bool
        let path: String
        let pushedAt: Date?
        let sizeKb: Int?
        let backupCount: Int?
        let lastSeenSeq: UInt64?
    }

    /// One entry returned by `csw cloud list-backups --json`. Slot 0 is the
    /// current bundle; slots >= 1 are ring-buffer copies, newest first.
    /// `decrypted == false` means we showed metadata only (no passphrase or
    /// wrong passphrase); in that case `seq` / `pushedAtInBundle` are absent.
    struct CloudBackupInfoDTO: Codable, Identifiable {
        let slot: Int
        let path: String
        let fileModTime: Date
        let sizeKb: Int64
        let decrypted: Bool
        let seq: UInt64?
        let pushedAtInBundle: Date?
        let accountCount: Int?

        var id: Int { slot }
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

    /// Lists every available bundle copy (current + ring-buffer backups).
    /// Pass an empty passphrase to get metadata only; pass the real one to
    /// decrypt each and reveal seq, pushed-at, and account count.
    func cloudListBackups(passphrase: String) async throws -> [CloudBackupInfoDTO] {
        try await runWithPassphraseDecoding(
            ["cloud", "list-backups", "--json"],
            passphrase: passphrase,
            decode: [CloudBackupInfoDTO].self
        )
    }

    /// Restores accounts from a specific ring-buffer slot. Slot 0 is identical
    /// to `cloudPull`; slots >= 1 walk back through older bundles. Bypasses
    /// anti-rollback on the backend side — an explicit user choice.
    func cloudRestoreBackup(slot: Int, passphrase: String) async throws {
        try await runWithPassphrase(
            ["cloud", "restore-backup", String(slot), "--json"],
            passphrase: passphrase
        )
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
        var args = ["mcp", "connectors", "connect"]
        if account == 0 {
            args.append("--shared")
        } else {
            args.append(contentsOf: ["--account", String(account)])
        }
        args.append(contentsOf: ["--service", service, "--token", "-"])
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
        clientSecret: String,
        displayName: String? = nil
    ) async throws {
        var args = ["mcp", "connectors", "connect"]
        if account == 0 {
            args.append("--shared")
        } else {
            args.append(contentsOf: ["--account", String(account)])
        }
        args.append(contentsOf: ["--service", "gdrive"])
        // Empty clientID means "use the build-time default baked into csw".
        if !clientID.isEmpty {
            args.append(contentsOf: ["--client-id", clientID])
        }
        if !clientSecret.isEmpty {
            args.append(contentsOf: ["--client-secret", clientSecret])
        }
        if let dn = displayName, !dn.isEmpty {
            args.append(contentsOf: ["--name", dn])
        }
        _ = try await runRaw(args)
    }

    func mcpConnectorDisconnect(account: Int, service: String) async throws {
        var args = ["mcp", "connectors", "disconnect"]
        if account == 0 {
            args.append("--shared")
        } else {
            args.append(contentsOf: ["--account", String(account)])
        }
        args.append(contentsOf: ["--service", service])
        _ = try await runRaw(args)
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
        _ = try await runWithPassphraseRaw(args, passphrase: passphrase)
    }

    private func runWithPassphraseDecoding<T: Decodable>(
        _ args: [String],
        passphrase: String,
        decode: T.Type
    ) async throws -> T {
        let raw = try await runWithPassphraseRaw(args, passphrase: passphrase)
        do {
            return try decoder.decode(T.self, from: raw)
        } catch {
            let str = String(data: raw, encoding: .utf8) ?? "<binary>"
            throw CswError.decodingFailed(underlying: error, raw: str)
        }
    }

    private func runWithPassphraseRaw(_ args: [String], passphrase: String) async throws -> Data {
        guard let bin = CswBinary.resolve() else { throw CswError.binaryNotFound }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
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
