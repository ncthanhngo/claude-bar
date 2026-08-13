import Foundation

/// DTOs for `csw netbird …`. Field names mirror the Go structs in
/// backend/internal/usecase/netbird (which in turn mirror the NetBird REST
/// API). The shared CswClient decoder does NOT convert snake_case, so every
/// snake_case wire key is mapped explicitly via CodingKeys. Arrays that the
/// API may emit as JSON null are optional and read through `?? []`.

struct NBGroupRef: Decodable, Hashable {
    let id: String
    let name: String
}

struct NBPeer: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let ip: String
    let connected: Bool
    let lastSeen: String
    let os: String
    let version: String
    let hostname: String
    let dnsLabel: String
    let sshEnabled: Bool
    let userID: String
    let groups: [NBGroupRef]?

    enum CodingKeys: String, CodingKey {
        case id, name, ip, connected, os, version, hostname, groups
        case lastSeen = "last_seen"
        case dnsLabel = "dns_label"
        case sshEnabled = "ssh_enabled"
        case userID = "user_id"
    }

    var groupNames: [String] { (groups ?? []).map(\.name) }
}

struct NBGroup: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let peersCount: Int
    let peers: [NBGroupRef]?

    enum CodingKeys: String, CodingKey {
        case id, name, peers
        case peersCount = "peers_count"
    }
}

struct NBRule: Decodable, Hashable {
    let id: String
    let name: String
    let enabled: Bool
    let action: String
    let bidirectional: Bool
    let `protocol`: String
    let sources: [NBGroupRef]?
    let destinations: [NBGroupRef]?
}

struct NBPolicy: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let enabled: Bool
    let rules: [NBRule]?
}

struct NBAccessEdge: Decodable, Hashable {
    let policyId: String
    let sourceGroup: String
    let destGroup: String
}

struct NBOverview: Decodable {
    let peers: [NBPeer]
    let groups: [NBGroup]
    let policies: [NBPolicy]
    let access: [NBAccessEdge]
    let external: [NBPolicy]
}

struct NBSetupKey: Decodable {
    let key: String
    let name: String
    let state: String?
    let expires: String?
}

/// Metadata for an existing setup key (from `setup-key list`). No plaintext key
/// — NetBird only returns that on create. `id` is normalized to a string Go-side.
struct NBSetupKeyInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let state: String
    let valid: Bool
    let revoked: Bool
    let usedTimes: Int
    let usageLimit: Int
    let expires: String
    let ephemeral: Bool
    let type: String
}

struct NBConfigStatus: Decodable {
    let configured: Bool
    let baseURL: String
}
