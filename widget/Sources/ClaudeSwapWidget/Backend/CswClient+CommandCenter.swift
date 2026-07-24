import Foundation

/// Phase 3/7/9/10 — backend RPCs the Command Center Diagnostics cards call.
/// Each maps 1:1 to a `csw <subcommand>` invocation.
extension CswClient {
    // MARK: - SSH (Phase 3)

    struct SSHHostDTO: Codable, Identifiable, Equatable {
        let name: String
        let label: String?
        let hostName: String?
        let port: Int?
        let user: String?
        let identityFile: String?
        let jumpHost: String?
        let note: String?
        let addedAt: Date?
        let lastConnected: Date?
        // Opt-in flags for the server health monitor (absent → false / "").
        let monitor: Bool?
        let diskPath: String?
        // True when a password is stored (in the Keychain) for this host.
        let passwordAuth: Bool?

        var id: String { name }
        var isMonitored: Bool { monitor == true }
        var hasPassword: Bool { passwordAuth == true }
        /// UI name: the label when set, else the stable identity.
        var displayName: String {
            if let l = label, !l.isEmpty { return l }
            return name
        }
    }

    func sshList() async throws -> [SSHHostDTO] {
        try await self.run(["ssh", "list"], decode: [SSHHostDTO].self)
    }

    func sshImportFromConfig() async throws {
        _ = try await self.runRaw(["ssh", "import"])
    }

    func sshRemove(name: String) async throws {
        _ = try await self.runRaw(["ssh", "remove", "--name", name])
    }

    func sshAdd(name: String, host: String, port: Int, user: String,
                identity: String = "", jump: String = "", note: String = "",
                display: String = "", diskPath: String = "") async throws {
        var args = ["ssh", "add", "--name", name]
        if !display.isEmpty { args += ["--display", display] }
        if !host.isEmpty { args += ["--host", host] }
        if port > 0 { args += ["--port", String(port)] }
        if !user.isEmpty { args += ["--user", user] }
        if !identity.isEmpty { args += ["--identity", identity] }
        if !jump.isEmpty { args += ["--jump", jump] }
        if !note.isEmpty { args += ["--note", note] }
        if !diskPath.isEmpty { args += ["--disk-path", diskPath] }
        _ = try await self.runRaw(args)
    }

    /// Edit an existing host in place. Only non-nil fields are sent; the
    /// backend preserves everything else (monitor flag, addedAt, …). Pass an
    /// empty string to clear a field (e.g. `identity: ""` drops the key,
    /// `displayName: ""` reverts to the identity name).
    func sshUpdate(name: String, displayName: String? = nil, host: String? = nil,
                   user: String? = nil, port: Int? = nil, identity: String? = nil,
                   diskPath: String? = nil) async throws {
        var args = ["ssh", "update", "--name", name]
        if let displayName { args += ["--display", displayName] }
        if let host { args += ["--host", host] }
        if let user { args += ["--user", user] }
        if let port { args += ["--port", String(port)] }
        if let identity { args += ["--identity", identity] }
        if let diskPath { args += ["--disk-path", diskPath] }
        _ = try await self.runRaw(args)
    }

    /// Store or clear a host's SSH password (Keychain-backed). The password
    /// travels on stdin, never argv. Empty string clears it. Sets the host's
    /// passwordAuth flag so Exec attempts password-then-key auth.
    func sshSetPassword(host: String, password: String) async throws {
        try await runWithStdin(["ssh", "set-password", "--host", host], stdin: password)
    }

    // MARK: - GitLab (Phase 7)

    struct GitLabInstanceDTO: Codable, Identifiable, Equatable {
        let id: String
        let name: String
        let baseUrl: String
        let note: String?
        let addedAt: Date?
    }

    func gitlabList() async throws -> [GitLabInstanceDTO] {
        try await self.run(["gitlab", "list"], decode: [GitLabInstanceDTO].self)
    }

    func gitlabAdd(name: String, baseURL: String, note: String, pat: String) async throws {
        try await self.runWithStdin(
            ["gitlab", "add", "--name", name, "--baseurl", baseURL, "--note", note],
            stdin: pat
        )
    }

    func gitlabRemove(id: String) async throws {
        _ = try await self.runRaw(["gitlab", "remove", "--id", id])
    }

    // MARK: - CI Tools (Daily → Tools: ci-watch + glpush installer)

    /// Machine-wide install state for the ci-watch/glpush tooling. Mirrors
    /// the Go `citools.Status` JSON (flat keys).
    struct CIToolsStatusDTO: Codable, Equatable {
        let brew: Bool
        let glab: Bool
        let gh: Bool
        let ghAuthed: Bool
        let ciWatch: Bool
        let glpush: Bool
        let instances: Int
        let hostsAuthed: [String]?
        let installed: Bool
    }

    /// `citools install` result — Status fields (embedded, so flat) + a step log.
    struct CIToolsInstallDTO: Codable, Equatable {
        let brew: Bool
        let glab: Bool
        let gh: Bool
        let ghAuthed: Bool
        let ciWatch: Bool
        let glpush: Bool
        let instances: Int
        let hostsAuthed: [String]?
        let installed: Bool
        let log: [String]

        var status: CIToolsStatusDTO {
            CIToolsStatusDTO(brew: brew, glab: glab, gh: gh, ghAuthed: ghAuthed,
                             ciWatch: ciWatch, glpush: glpush, instances: instances,
                             hostsAuthed: hostsAuthed, installed: installed)
        }
    }

    func citoolsStatus() async throws -> CIToolsStatusDTO {
        try await self.run(["citools", "status"], decode: CIToolsStatusDTO.self)
    }

    func citoolsInstall() async throws -> CIToolsInstallDTO {
        try await self.run(["citools", "install"], decode: CIToolsInstallDTO.self)
    }

    // MARK: - Bitwarden (Phase 9)

    struct BWStatusDTO: Codable, Equatable {
        let binaryFound: Bool
        let binaryPath: String?
        let unlocked: Bool
        let unlockedAt: String?
        let serverUrl: String?
        let userEmail: String?
    }

    func bwStatus() async throws -> BWStatusDTO {
        try await self.run(["bw", "status"], decode: BWStatusDTO.self)
    }

    func bwUnlock(passphrase: String) async throws {
        try await self.runWithStdin(["bw", "unlock"], stdin: passphrase)
    }

    func bwLock() async throws {
        _ = try await self.runRaw(["bw", "lock"])
    }

    // MARK: - Audit (Phase 10)

    struct AuditEventDTO: Codable, Identifiable, Equatable {
        let ts: Date
        let kind: String
        let tool: String?
        let account: String?
        let outcome: String
        let latencyMs: Int?
        let argsHash: String?

        var id: String { (tool ?? kind) + ts.timeIntervalSince1970.description }
    }

    func auditTail(lines: Int = 50) async throws -> [AuditEventDTO] {
        try await self.run(["audit", "tail", "-n", String(lines)], decode: [AuditEventDTO].self)
    }

    func auditPath() async throws -> String {
        let data = try await self.runRaw(["audit", "path"])
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Repomap (Phase 4 — repo-link resolution)

    struct RepoEntryDTO: Codable, Identifiable, Equatable {
        let origin: String
        let localPath: String
        let discoveredAt: Date?

        var id: String { origin + "|" + localPath }
    }

    struct RepoScanResultDTO: Codable, Equatable {
        let entries: Int
        let roots: [String]
    }

    func repomapScan(roots: [String]? = nil) async throws -> RepoScanResultDTO {
        var args = ["repomap", "scan"]
        if let r = roots, !r.isEmpty {
            args += ["--roots", r.joined(separator: ",")]
        }
        return try await self.run(args, decode: RepoScanResultDTO.self)
    }

    func repomapLookup(origin: String) async throws -> String {
        struct R: Decodable { let localPath: String }
        let r = try await self.run(["repomap", "lookup", "--origin", origin], decode: R.self)
        return r.localPath
    }

    func repomapList() async throws -> [RepoEntryDTO] {
        try await self.run(["repomap", "list"], decode: [RepoEntryDTO].self)
    }

    // MARK: - SSH bundle (Phase 3 — encrypted .cbssh export/import)

    func sshExportBundle(toPath path: String, passphrase: String) async throws {
        try await self.runWithStdin(["ssh", "export-bundle", "--out", path], stdin: passphrase)
    }

    func sshImportBundle(fromPath path: String, passphrase: String, merge: Bool = true) async throws {
        var args = ["ssh", "import-bundle", "--in", path]
        if !merge { args += ["--merge=false"] }
        try await self.runWithStdin(args, stdin: passphrase)
    }
}
