import Foundation

/// One machine on the NetBird network, as reported by the local client.
struct NetbirdPeer: Identifiable, Equatable {
    let fqdn: String
    let ip: String
    let isConnected: Bool
    /// "P2P" / "Relayed"; empty while the peer is not connected.
    let connectionType: String
    let latencyMs: Int?

    var id: String { fqdn }

    /// First DNS label — the name given to the machine on the dashboard.
    var name: String { fqdn.split(separator: ".").first.map(String.init) ?? fqdn }
}

/// Peer list for the NetBird tab. Reads `netbird status --json` from the
/// locally installed client, so the list always matches the network without
/// any manual host entry or API token.
@MainActor
final class NetbirdPeerStore: ObservableObject {
    @Published private(set) var peers: [NetbirdPeer] = []
    @Published private(set) var isLoading = false
    /// User-facing reason the list could not be loaded; nil when it loaded.
    @Published private(set) var error: String?

    /// Per-peer SSH usernames the user typed, keyed by FQDN.
    @Published private(set) var users: [String: String]

    /// Free-text labels (e.g. who uses the machine), keyed by FQDN. Local to
    /// this Mac; the NetBird dashboard never sees them.
    @Published private(set) var labels: [String: String]

    static let defaultUser = "evseadmin"
    private static let usersKey = "netbirdSSHUsers"
    private static let labelsKey = "netbirdPeerLabels"

    init() {
        users = UserDefaults.standard.dictionary(forKey: Self.usersKey) as? [String: String] ?? [:]
        labels = UserDefaults.standard.dictionary(forKey: Self.labelsKey) as? [String: String] ?? [:]
    }

    /// Where the NetBird CLI lives (pkg install, then Homebrew); nil if absent.
    static var binaryPath: String? {
        ["/usr/local/bin/netbird", "/opt/homebrew/bin/netbird"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() async {
        guard !isLoading else { return }
        guard let bin = Self.binaryPath else {
            error = "Không tìm thấy NetBird trên máy này."
            return
        }
        isLoading = true
        let output = await Task.detached { Shell.run(bin, ["status", "--json"]) }.value
        isLoading = false
        if let parsed = Self.parse(output) {
            peers = parsed
            error = nil
        } else {
            error = "NetBird chưa chạy hoặc chưa kết nối."
        }
    }

    func user(for peer: NetbirdPeer) -> String {
        users[peer.fqdn] ?? Self.defaultUser
    }

    func setUser(_ user: String, for peer: NetbirdPeer) {
        let trimmed = user.trimmingCharacters(in: .whitespaces)
        users[peer.fqdn] = trimmed.isEmpty || trimmed == Self.defaultUser ? nil : trimmed
        UserDefaults.standard.set(users, forKey: Self.usersKey)
    }

    func label(for peer: NetbirdPeer) -> String {
        labels[peer.fqdn] ?? ""
    }

    func setLabel(_ label: String, for peer: NetbirdPeer) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed != self.label(for: peer) else { return }
        labels[peer.fqdn] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(labels, forKey: Self.labelsKey)
    }

    func connect(_ peer: NetbirdPeer) {
        guard let bin = Self.binaryPath else { return }
        SSHTerminalLauncher.openNetbird(binary: bin, user: user(for: peer), host: peer.fqdn)
    }

    /// The command to paste into any terminal to SSH into this machine; nil
    /// when the saved username is not a plain account name.
    func sshCommand(for peer: NetbirdPeer) -> String? {
        SSHTerminalLauncher.netbirdCommand(binary: "netbird", user: user(for: peer), host: peer.fqdn)
    }

    /// Decodes `netbird status --json`. Connected peers first, then by name.
    /// Returns nil when the output is not the expected JSON (daemon down).
    nonisolated static func parse(_ json: String) -> [NetbirdPeer]? {
        guard let data = json.data(using: .utf8),
              let status = try? JSONDecoder().decode(StatusDTO.self, from: data) else { return nil }
        return (status.peers.details ?? [])
            .map { d in
                let connected = d.status == "Connected"
                return NetbirdPeer(
                    fqdn: d.fqdn,
                    ip: d.netbirdIp,
                    isConnected: connected,
                    connectionType: connected ? (d.connectionType ?? "") : "",
                    // Reported in nanoseconds; 0 means not measured yet.
                    latencyMs: d.latency.flatMap { $0 > 0 ? Int(($0 / 1_000_000).rounded()) : nil }
                )
            }
            .sorted { a, b in
                if a.isConnected != b.isConnected { return a.isConnected }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private struct StatusDTO: Decodable {
        let peers: Peers
        struct Peers: Decodable { let details: [Detail]? }
        struct Detail: Decodable {
            let fqdn: String
            let netbirdIp: String
            let status: String
            let connectionType: String?
            let latency: Double?
        }
    }
}
