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

    /// One process for the whole poll cycle. Collapses the three concurrent
    /// forks the refresh loop used to spawn — `list --metadata-only`,
    /// `sessions`, `usage-stats` — into a single `csw refresh-bundle` call,
    /// cutting steady-state process spawns per refresh by ~66%. `usageStats`
    /// is optional: the backend omits it when its scan fails so a transient
    /// token-log error doesn't blank the panel (matches the previous `try?`).
    struct RefreshBundleDTO: Decodable {
        let list: ListAccountsDTO
        let report: SessionReportDTO
        let usageStats: UsageStatsDTO?
    }

    func refreshBundle() async throws -> RefreshBundleDTO {
        try await run(["refresh-bundle", "--json"], decode: RefreshBundleDTO.self)
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

    /// Result of `csw ingest-oauth` — reports which slots were rewritten.
    struct IngestOAuthDTO: Codable {
        let account: AccountDTO
        let wroteLive: Bool
        let wroteBackup: Bool
    }

    /// Writes a fresh OAuth payload (from the in-app WebView re-login) into the
    /// given account's slots. Stdin-piped so tokens never appear in argv. The
    /// backend refuses the call if `expectedEmail` is set and disagrees with the
    /// account's registered email — protects against signing in as the wrong
    /// Anthropic account during the WebView consent step.
    func ingestOAuth(
        accountNum: Int,
        accessToken: String,
        refreshToken: String,
        expiresAt: Int64,
        scopes: [String],
        subscriptionType: String?,
        expectedEmail: String?
    ) async throws -> IngestOAuthDTO {
        var payload: [String: Any] = [
            "accountNum": accountNum,
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": expiresAt,
            "scopes": scopes,
        ]
        if let sub = subscriptionType, !sub.isEmpty {
            payload["subscriptionType"] = sub
        }
        if let email = expectedEmail, !email.isEmpty {
            payload["expectedEmail"] = email
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let raw = String(data: data, encoding: .utf8) ?? "{}"
        return try await runWithStdinDecoding(
            ["ingest-oauth", "--json"],
            stdin: raw,
            decode: IngestOAuthDTO.self
        )
    }

    /// Creates a NEW account from a WebView OAuth payload (the add-account
    /// primary flow). Dedupes by (email, orgUuid) server-side; writes only the
    /// backup slot, never the live credential, so adding never disrupts the
    /// running CLI session. `orgUuid` is required — the backend refuses to
    /// dedupe without it rather than risk overwriting another org's account.
    func addAccountFromOAuth(
        accessToken: String,
        refreshToken: String,
        expiresAt: Int64,
        scopes: [String],
        subscriptionType: String?,
        email: String,
        orgUuid: String,
        organizationName: String?,
        nickname: String?
    ) async throws -> AddAccountDTO {
        var payload: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": expiresAt,
            "scopes": scopes,
            "email": email,
            "orgUuid": orgUuid,
        ]
        if let sub = subscriptionType, !sub.isEmpty { payload["subscriptionType"] = sub }
        if let org = organizationName, !org.isEmpty { payload["organizationName"] = org }
        if let nick = nickname, !nick.isEmpty { payload["nickname"] = nick }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let raw = String(data: data, encoding: .utf8) ?? "{}"
        return try await runWithStdinDecoding(
            ["add-oauth", "--json"],
            stdin: raw,
            decode: AddAccountDTO.self
        )
    }

    private func runWithStdinDecoding<T: Decodable>(
        _ args: [String],
        stdin payload: String,
        decode: T.Type
    ) async throws -> T {
        guard let bin = CswBinary.resolve() else { throw CswError.binaryNotFound }
        let raw = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
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
                if let data = payload.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                cont.resume(throwing: error)
            }
        }
        do {
            return try decoder.decode(T.self, from: raw)
        } catch {
            let str = String(data: raw, encoding: .utf8) ?? "<binary>"
            throw CswError.decodingFailed(underlying: error, raw: str)
        }
    }

    /// Public stdin+decode entry point for callers that pass a JSON payload on
    /// stdin and expect a decoded JSON response (e.g. the Workspace drafter).
    func runWithStdin<T: Decodable>(_ args: [String], stdin payload: String, decode: T.Type) async throws -> T {
        try await runWithStdinDecoding(args, stdin: payload, decode: decode)
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
