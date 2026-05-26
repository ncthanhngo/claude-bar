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
        // Date.ISO8601FormatStyle is Sendable; the older ISO8601DateFormatter
        // class is not, so the @Sendable strategy closure could not safely
        // capture it under Swift 6 strict concurrency. The two styles cover
        // both wire formats csw emits (with and without fractional seconds).
        let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        d.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            if let date = try? withFractional.parse(str) { return date }
            if let date = try? plain.parse(str) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unparseable ISO8601 date: \(str)"
            ))
        }
        return d
    }()

    func list(includeUsage: Bool = true, usageAccounts: [Int]? = nil) async throws -> ListAccountsDTO {
        var args = ["list", "--json"]
        if let usageAccounts {
            args.append("--usage-accounts=\(usageAccounts.map(String.init).joined(separator: ","))")
        } else if !includeUsage {
            args.append("--metadata-only")
        }
        return try await run(args, decode: ListAccountsDTO.self)
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

    func usageStats() async throws -> UsageStatsDTO {
        try await run(["usage-stats", "--json"], decode: UsageStatsDTO.self)
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

    /// One row in the restore-preview table. `status` is one of
    /// "remoteOnly", "both", "localOnly".
    struct CloudPreviewRowDTO: Codable, Identifiable {
        let identity: String
        let email: String
        let nickname: String?
        let organizationName: String?
        let organizationUuid: String?
        let localCreatedAt: Date?
        let remoteCreatedAt: Date?
        let status: String

        var id: String { identity }
    }

    /// Decrypts the bundle at `slot` (0 = current) and returns a merged view
    /// of local registry vs bundle accounts. Read-only.
    func cloudPreview(slot: Int, passphrase: String) async throws -> [CloudPreviewRowDTO] {
        try await runWithPassphraseDecoding(
            ["cloud", "preview", String(slot), "--json"],
            passphrase: passphrase,
            decode: [CloudPreviewRowDTO].self
        )
    }

    /// Restores only the bundle entries whose identity is in `identities`.
    /// Identity = "email|orgUUID" (matches `CloudPreviewRowDTO.identity`).
    func cloudPullSelective(slot: Int, passphrase: String, identities: [String]) async throws {
        let json = try String(data: JSONEncoder().encode(identities), encoding: .utf8) ?? "[]"
        try await runWithPassphrase(
            ["cloud", "pull-selective", String(slot), "--json"],
            passphrase: passphrase,
            extraStdin: json
        )
    }

    /// Encrypts the local bundle to an arbitrary file path. Used for the
    /// cross-Apple-ID share flow — the recipient imports the file with the
    /// same passphrase via `cloudImportPreview` + `cloudImportSelective`.
    func cloudExport(passphrase: String, destPath: String) async throws {
        try await runWithPassphrase(
            ["cloud", "export", destPath, "--json"],
            passphrase: passphrase
        )
    }

    /// Decrypts an externally-supplied bundle file and returns the side-by-side
    /// comparison rows (mirrors `cloudPreview` but reads from `srcPath` instead
    /// of an iCloud ring-buffer slot). Read-only.
    func cloudImportPreview(passphrase: String, srcPath: String) async throws -> [CloudPreviewRowDTO] {
        try await runWithPassphraseDecoding(
            ["cloud", "import-preview", srcPath, "--json"],
            passphrase: passphrase,
            decode: [CloudPreviewRowDTO].self
        )
    }

    /// Applies selected accounts from an externally-supplied bundle file.
    /// Bypasses anti-rollback (imported bundle is on a different sync chain)
    /// and does NOT update the local iCloud sync state.
    func cloudImportSelective(passphrase: String, srcPath: String, identities: [String]) async throws {
        let json = try String(data: JSONEncoder().encode(identities), encoding: .utf8) ?? "[]"
        try await runWithPassphrase(
            ["cloud", "import-selective", srcPath, "--json"],
            passphrase: passphrase,
            extraStdin: json
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

    /// Outcome of `csw mcp connectors reconnect` — the Go side returns
    /// distinct exit codes for the two cases the Swift UI needs to
    /// branch on (saved credential still valid vs. invalid + must
    /// prompt for fresh).
    enum ReconnectOutcome {
        /// Saved credential verified and Enabled flipped back to true.
        case reEnabled
        /// Saved credential present but rejected by the provider —
        /// caller should fall through to the existing connect-sheet
        /// flow so the user can paste a fresh token / re-run OAuth.
        case needsFreshCredential(detail: String)
    }

    func mcpConnectorForget(account: Int, service: String) async throws {
        var args = ["mcp", "connectors", "forget"]
        if account == 0 {
            args.append("--shared")
        } else {
            args.append(contentsOf: ["--account", String(account)])
        }
        args.append(contentsOf: ["--service", service])
        _ = try await runRaw(args)
    }

    func mcpConnectorReconnect(account: Int, service: String) async throws -> ReconnectOutcome {
        var args = ["mcp", "connectors", "reconnect"]
        if account == 0 {
            args.append("--shared")
        } else {
            args.append(contentsOf: ["--account", String(account)])
        }
        args.append(contentsOf: ["--service", service])
        do {
            _ = try await runRaw(args)
            return .reEnabled
        } catch CswError.nonZeroExit(let code, let stderr) where code == 2 {
            return .needsFreshCredential(detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func mcpToolsList(service: String) async throws -> [MCPToolSummaryDTO] {
        try await run(["mcp", "tools", "list", "--service", service, "--json"], decode: [MCPToolSummaryDTO].self)
    }

    func mcpToolsSetEnabled(toolID: String, enabled: Bool) async throws {
        // Bool flags in Go's `flag` package MUST use `--name=value` form —
        // the space-separated `--name value` form silently treats `--name`
        // as a no-arg switch (defaulting to true) and drops `value` as an
        // ignored positional. The previous shape sent `--enabled false`
        // which evaluated to `enabled=true`, so the OFF toggle never
        // actually persisted to the registry.
        _ = try await runRaw(["mcp", "tools", "set-enabled", "--tool", toolID, "--enabled=\(enabled ? "true" : "false")"])
    }

    func mcpConnectorSetEnabled(account: Int, service: String, enabled: Bool) async throws {
        var args = ["mcp", "connectors", "set-enabled"]
        if account == 0 {
            args.append("--shared")
        } else {
            args.append(contentsOf: ["--account", String(account)])
        }
        // See mcpToolsSetEnabled — Go bool flags need `--enabled=false`.
        args.append(contentsOf: ["--service", service, "--enabled=\(enabled ? "true" : "false")"])
        _ = try await runRaw(args)
    }

    func runWithStdin(_ args: [String], stdin payload: String) async throws {
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

    private func runWithPassphrase(_ args: [String], passphrase: String, extraStdin: String? = nil) async throws {
        _ = try await runWithPassphraseRaw(args, passphrase: passphrase, extraStdin: extraStdin)
    }

    private func runWithPassphraseDecoding<T: Decodable>(
        _ args: [String],
        passphrase: String,
        decode: T.Type,
        extraStdin: String? = nil
    ) async throws -> T {
        let raw = try await runWithPassphraseRaw(args, passphrase: passphrase, extraStdin: extraStdin)
        do {
            return try decoder.decode(T.self, from: raw)
        } catch {
            let str = String(data: raw, encoding: .utf8) ?? "<binary>"
            throw CswError.decodingFailed(underlying: error, raw: str)
        }
    }

    private func runWithPassphraseRaw(_ args: [String], passphrase: String, extraStdin: String? = nil) async throws -> Data {
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
                var payload = passphrase + "\n"
                if let extra = extraStdin {
                    payload += extra + "\n"
                }
                stdin.fileHandleForWriting.write(payload.data(using: .utf8)!)
                stdin.fileHandleForWriting.closeFile()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    func run<T: Decodable>(_ args: [String], decode: T.Type) async throws -> T {
        let raw = try await runRaw(args)
        do {
            return try decoder.decode(T.self, from: raw)
        } catch {
            let str = String(data: raw, encoding: .utf8) ?? "<binary>"
            throw CswError.decodingFailed(underlying: error, raw: str)
        }
    }

    func runRaw(_ args: [String]) async throws -> Data {
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
