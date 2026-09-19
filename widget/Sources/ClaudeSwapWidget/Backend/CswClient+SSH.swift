import Foundation

/// Backend RPCs for the SSH host registry behind the server monitor.
/// Each maps 1:1 to a `csw ssh <subcommand>` invocation.
extension CswClient {
    // MARK: - Host registry

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
        // TCP port probed on the server loopback (0/absent = off).
        let checkPort: Int?
        // Comma/space list of systemd units / docker:<name> tokens to watch.
        let services: String?

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


    func sshRemove(name: String) async throws {
        _ = try await self.runRaw(["ssh", "remove", "--name", name])
    }

    func sshAdd(name: String, host: String, port: Int, user: String,
                identity: String = "", jump: String = "", note: String = "",
                display: String = "", diskPath: String = "", checkPort: Int = 0,
                services: String = "") async throws {
        var args = ["ssh", "add", "--name", name]
        if !display.isEmpty { args += ["--display", display] }
        if !host.isEmpty { args += ["--host", host] }
        if port > 0 { args += ["--port", String(port)] }
        if !user.isEmpty { args += ["--user", user] }
        if !identity.isEmpty { args += ["--identity", identity] }
        if !jump.isEmpty { args += ["--jump", jump] }
        if !note.isEmpty { args += ["--note", note] }
        if !diskPath.isEmpty { args += ["--disk-path", diskPath] }
        if checkPort > 0 { args += ["--check-port", String(checkPort)] }
        if !services.isEmpty { args += ["--services", services] }
        _ = try await self.runRaw(args)
    }

    /// Edit an existing host in place. Only non-nil fields are sent; the
    /// backend preserves everything else (monitor flag, addedAt, …). Pass an
    /// empty string to clear a field (e.g. `identity: ""` drops the key,
    /// `displayName: ""` reverts to the identity name).
    func sshUpdate(name: String, displayName: String? = nil, host: String? = nil,
                   user: String? = nil, port: Int? = nil, identity: String? = nil,
                   diskPath: String? = nil, jump: String? = nil, checkPort: Int? = nil,
                   services: String? = nil) async throws {
        var args = ["ssh", "update", "--name", name]
        if let displayName { args += ["--display", displayName] }
        if let host { args += ["--host", host] }
        if let user { args += ["--user", user] }
        if let port { args += ["--port", String(port)] }
        if let identity { args += ["--identity", identity] }
        if let diskPath { args += ["--disk-path", diskPath] }
        if let jump { args += ["--jump", jump] }
        if let checkPort { args += ["--check-port", String(checkPort)] }
        if let services { args += ["--services", services] }
        _ = try await self.runRaw(args)
    }

    /// Store or clear a host's SSH password (Keychain-backed). The password
    /// travels on stdin, never argv. Empty string clears it. Sets the host's
    /// passwordAuth flag so Exec attempts password-then-key auth.
    func sshSetPassword(host: String, password: String) async throws {
        try await runWithStdin(["ssh", "set-password", "--host", host], stdin: password)
    }

    /// Drop the host's stale known_hosts entry (trust its new key) so the next
    /// probe re-pins it.
    func sshTrustKey(host: String) async throws {
        _ = try await self.runRaw(["ssh", "trust-key", "--host", host])
    }

    // MARK: - Encrypted .cbssh export/import

    func sshExportBundle(toPath path: String, passphrase: String) async throws {
        try await self.runWithStdin(["ssh", "export-bundle", "--out", path], stdin: passphrase)
    }

    func sshImportBundle(fromPath path: String, passphrase: String, merge: Bool = true) async throws {
        var args = ["ssh", "import-bundle", "--in", path]
        if !merge { args += ["--merge=false"] }
        try await self.runWithStdin(args, stdin: passphrase)
    }
}

/// Convenience accessors over the (optional-heavy) backend SSH host DTO.
extension CswClient.SSHHostDTO {
    var hostNameOr: String { hostName ?? "" }
    var userOr: String { user ?? "" }
    var portOr: Int { port ?? 0 }

    /// "user@host" target, or just host when no user is set.
    var target: String {
        let h = hostName ?? ""
        let u = user ?? ""
        return u.isEmpty ? h : "\(u)@\(h)"
    }
}
