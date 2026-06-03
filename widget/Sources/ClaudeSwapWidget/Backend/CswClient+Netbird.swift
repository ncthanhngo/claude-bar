import Foundation

/// NetBird subprocess calls. Mirrors backend/cmd/csw/cmd_netbird.go.
extension CswClient {
    func netbirdConfigShow() async throws -> NBConfigStatus {
        try await run(["netbird", "config", "show", "--json"], decode: NBConfigStatus.self)
    }

    /// Saves the token (piped over stdin so it never appears in argv). The Go
    /// side verifies connectivity before returning, so a bad token/URL throws.
    func netbirdConfigSet(baseURL: String, token: String) async throws {
        var args = ["netbird", "config", "set", "--json"]
        if !baseURL.isEmpty { args.append(contentsOf: ["--base-url", baseURL]) }
        args.append(contentsOf: ["--token", "-"])
        try await runWithStdin(args, stdin: token)
    }

    func netbirdOverview() async throws -> NBOverview {
        try await run(["netbird", "overview", "--json"], decode: NBOverview.self)
    }

    /// Grants src-group → dst-group access (matrix cell ON). Idempotent.
    func netbirdGrant(srcGroup: String, dstGroup: String) async throws {
        _ = try await runRaw(["netbird", "grant", "--json", "--src-group", srcGroup, "--dst-group", dstGroup])
    }

    /// Revokes access by deleting the policy (matrix cell OFF).
    func netbirdRevoke(policyID: String) async throws {
        _ = try await runRaw(["netbird", "revoke", "--json", "--policy", policyID])
    }

    /// Creates an enrollment key auto-assigning new machines to `group`.
    /// `usageLimit` 1 makes the key single-use (one machine per key) so a
    /// deleted machine can't silently rejoin; 0 means unlimited.
    func netbirdSetupKeyCreate(name: String, group: String, expiresDays: Int, usageLimit: Int = 1) async throws -> NBSetupKey {
        try await run([
            "netbird", "setup-key", "create", "--json",
            "--name", name,
            "--group", group,
            "--expires-days", String(expiresDays),
            "--usage-limit", String(usageLimit),
        ], decode: NBSetupKey.self)
    }

    /// Lists existing setup keys (metadata only — no plaintext key).
    func netbirdSetupKeyList() async throws -> [NBSetupKeyInfo] {
        try await run(["netbird", "setup-key", "list", "--json"], decode: [NBSetupKeyInfo].self)
    }

    /// Revokes (deletes) a setup key so it can no longer enroll machines.
    func netbirdSetupKeyRevoke(id: String) async throws {
        _ = try await runRaw(["netbird", "setup-key", "revoke", "--json", "--id", id])
    }

    /// Adds a machine to `group` (creating it if needed) and drops it from
    /// dev-pending. Also used to assign any existing machine to a server/dev
    /// group, not just to approve a pending one.
    func netbirdPeerAssign(peerID: String, group: String) async throws {
        _ = try await runRaw(["netbird", "peer", "assign", "--json", "--id", peerID, "--group", group])
    }

    /// Removes a machine from `group` (membership only; the group itself stays).
    func netbirdPeerRemoveFromGroup(peerID: String, group: String) async throws {
        _ = try await runRaw(["netbird", "peer", "remove", "--json", "--id", peerID, "--group", group])
    }

    /// Rejects/removes a peer.
    func netbirdPeerDelete(peerID: String) async throws {
        _ = try await runRaw(["netbird", "peer", "delete", "--json", "--id", peerID])
    }

    /// Renames a peer (machine) for easier identification.
    func netbirdPeerRename(peerID: String, name: String) async throws {
        _ = try await runRaw(["netbird", "peer", "rename", "--json", "--id", peerID, "--name", name])
    }

    /// Renames a group (preserves membership).
    func netbirdGroupRename(groupID: String, name: String) async throws {
        _ = try await runRaw(["netbird", "group", "rename", "--json", "--id", groupID, "--name", name])
    }

    /// Creates an empty group. Idempotent: returns the existing group when the
    /// name is already taken. Returns its {id, name}.
    func netbirdGroupCreate(name: String) async throws -> NBGroupRef {
        try await run(["netbird", "group", "create", "--json", "--name", name], decode: NBGroupRef.self)
    }

    /// Deletes a group. Throws with NetBird's message when the group is still
    /// referenced by a policy / route / setup-key (nothing is unlinked).
    func netbirdGroupDelete(groupID: String) async throws {
        _ = try await runRaw(["netbird", "group", "delete", "--json", "--id", groupID])
    }
}
