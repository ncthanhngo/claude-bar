import Foundation
import AppKit

/// Convenience accessors over the (optional-heavy) backend SSH host DTO.
extension CswClient.SSHHostDTO {
    var hostNameOr: String { hostName ?? "" }
    var userOr: String { user ?? "" }
    var portOr: Int { port ?? 0 }
    var noteOr: String { note ?? "" }

    /// "user@host" target, or just host when no user is set.
    var target: String {
        let h = hostName ?? ""
        let u = user ?? ""
        return u.isEmpty ? h : "\(u)@\(h)"
    }
}

/// Backs the SSH manager pane. Wraps the `csw ssh` host registry (shared with
/// the cb_ssh_* MCP tools) and opens connections in Terminal.app.
@MainActor
final class SSHManagerStore: ObservableObject {
    @Published private(set) var hosts: [CswClient.SSHHostDTO] = []
    @Published private(set) var busy = false
    @Published var lastError: String?

    private let client: CswClient
    init(client: CswClient = CswClient()) { self.client = client }

    func load() async {
        busy = true; defer { busy = false }
        do { hosts = try await client.sshList().sorted { $0.name < $1.name }; lastError = nil }
        catch { lastError = CswError.redact(error.localizedDescription) }
    }

    func add(name: String, host: String, port: Int, user: String, note: String) async {
        busy = true; defer { busy = false }
        do {
            try await client.sshAdd(name: name, host: host, port: port, user: user, note: note)
            await load()
        } catch { lastError = CswError.redact(error.localizedDescription) }
    }

    func remove(_ name: String) async {
        busy = true; defer { busy = false }
        do { try await client.sshRemove(name: name); await load() }
        catch { lastError = CswError.redact(error.localizedDescription) }
    }

    /// Add any mesh servers not already tracked (name = peer name, host = dns
    /// label or IP). Lets the SSH pane reuse the NetBird servers in one click.
    func seedFromMesh(_ servers: [(name: String, host: String, user: String)]) async {
        let existing = Set(hosts.map(\.name))
        for s in servers where !existing.contains(s.name) {
            try? await client.sshAdd(name: s.name, host: s.host, port: 0, user: s.user, note: "from NetBird")
        }
        await load()
    }

    /// Open Terminal.app and run a plain `ssh` connection to the tracked host.
    func connect(_ h: CswClient.SSHHostDTO) {
        var parts = ["ssh"]
        if h.portOr > 0 { parts += ["-p", String(h.portOr)] }
        if let id = h.identityFile, !id.isEmpty { parts += ["-i", id] }
        if let j = h.jumpHost, !j.isEmpty { parts += ["-J", j] }
        parts.append(h.target.isEmpty ? h.name : h.target)
        runTerminal(parts.joined(separator: " "))
    }

    private func runTerminal(_ cmd: String) {
        let escaped = cmd.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch { lastError = error.localizedDescription }
    }
}
