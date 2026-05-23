import Foundation

/// Phase 3/7/9/10 — backend RPCs the Command Center Diagnostics cards call.
/// Each maps 1:1 to a `csw <subcommand>` invocation.
extension CswClient {
    // MARK: - SSH (Phase 3)

    struct SSHHostDTO: Codable, Identifiable, Equatable {
        let name: String
        let hostName: String?
        let port: Int?
        let user: String?
        let identityFile: String?
        let jumpHost: String?
        let note: String?
        let addedAt: Date?
        let lastConnected: Date?

        var id: String { name }
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
}
