import Foundation
import Combine
import AppKit
import SwiftUI

/// A server or dev node in the Workspace Netbird panel. Identity is its NetBird
/// group name (srv-… or dev-…); the member peer supplies live status.
struct NBNode: Identifiable, Hashable {
    let groupName: String
    let display: String
    let peer: NBPeer?

    var id: String { groupName }
    var online: Bool { peer?.connected ?? false }
    var version: String { peer?.version ?? "" }
}

/// Bridges the Netbird SwiftUI panel to `csw netbird` subcommands. Owns a light
/// refresh on open; mutations are applied immediately then re-fetched so the UI
/// always reflects the real NetBird state.
@MainActor
final class NetbirdCoordinator: ObservableObject {
    @Published private(set) var overview: NBOverview?
    @Published private(set) var configured = false
    @Published private(set) var baseURL = ""
    @Published private(set) var isLoading = false
    @Published private(set) var busy = false
    @Published var lastError: String?

    /// User-assigned group roles (server/dev). NetBird group names are arbitrary,
    /// so the matrix rows/cols come from these tags, not a naming convention.
    @Published var roles: [String: NBGroupRole]

    /// Per-group accent colors (groupName → 0xRRGGBB) for visual distinction.
    @Published var colors: [String: UInt32]

    /// Per-group freeform markdown notes (groupName → markdown), shown on hover.
    @Published var notes: [String: String]

    /// Enrollment recipient directory — who a single-use key gets named after
    /// and emailed to. Local contact metadata, not a NetBird concept.
    @Published var people: [NetbirdPerson]

    private let client: CswClient
    init(client: CswClient = CswClient()) {
        self.client = client
        self.roles = NetbirdRolesStore.load()
        self.colors = NetbirdColorsStore.load()
        self.notes = NetbirdNotesStore.load()
        self.people = NetbirdPeopleStore.load()
    }

    // MARK: recipient directory

    /// Insert or update a recipient (matched by id) and persist.
    func upsertPerson(_ p: NetbirdPerson) {
        if let i = people.firstIndex(where: { $0.id == p.id }) { people[i] = p }
        else { people.append(p) }
        people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        NetbirdPeopleStore.save(people)
    }

    /// Remove a recipient by id and persist.
    func removePerson(_ id: String) {
        people.removeAll { $0.id == id }
        NetbirdPeopleStore.save(people)
    }

    // MARK: group colors

    func setColor(_ hex: UInt32?, for group: String) {
        if let hex { colors[group] = hex } else { colors.removeValue(forKey: group) }
        NetbirdColorsStore.save(colors)
    }

    /// Accent color for a group, or nil to let callers fall back to a default.
    func color(forGroup group: String) -> Color? {
        colors[group].map { Color(hex: $0) }
    }

    // MARK: group notes

    /// Upsert a group's markdown note. Whitespace-only trims to a removal so a
    /// cleared note doesn't linger in UserDefaults (and `note(forGroup:)` stays
    /// the single "has a note?" signal for the hover affordance).
    func setNote(_ markdown: String, for group: String) {
        let t = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { notes.removeValue(forKey: group) } else { notes[group] = t }
        NetbirdNotesStore.save(notes)
    }

    /// Markdown note for a group, or nil when none has been written.
    func note(forGroup group: String) -> String? {
        notes[group]
    }

    // MARK: special groups (still convention-based — enrollment + reverse support)
    static let pendingGroup = "dev-pending"   // setup keys auto-assign new machines here
    static let adminGroup = "admin"           // source group for reverse support

    /// The "All" group and the pending group are never matrix rows/cols.
    static let reservedGroups: Set<String> = ["All", pendingGroup]

    // MARK: role assignment

    func setRole(_ role: NBGroupRole?, for group: String) {
        if let role { roles[group] = role } else { roles.removeValue(forKey: group) }
        NetbirdRolesStore.save(roles)
    }

    /// First-load convenience: guess server/dev from group names so the matrix
    /// fills itself instead of forcing manual setup. Only groups with no role
    /// yet are touched, so it never overrides the admin's own choices. Common
    /// keywords: server/vps/srv/prod/staging/api/db/web → server; dev/laptop →
    /// dev. Anything ambiguous is left unset for the admin to tag via the gear.
    func autoInferRolesIfNeeded() {
        let serverHints = ["server", "vps", "srv", "prod", "staging", "stag", "api", "db", "web", "ci", "infra"]
        let devHints = ["dev", "laptop", "workstation", "macbook", "client"]
        for g in (overview?.groups ?? []) {
            let name = g.name
            if Self.reservedGroups.contains(name) || roles[name] != nil { continue }
            let n = name.lowercased()
            if serverHints.contains(where: n.contains) {
                roles[name] = .server
            } else if devHints.contains(where: n.contains) {
                roles[name] = .dev
            }
        }
        NetbirdRolesStore.save(roles)
    }

    /// Groups the admin can still classify (have no role yet, not reserved).
    var unclassifiedGroups: [String] {
        (overview?.groups ?? [])
            .map(\.name)
            .filter { !Self.reservedGroups.contains($0) && roles[$0] == nil }
            .sorted()
    }

    // MARK: derived view models

    var servers: [NBNode] { nodes(role: .server) }
    var devs: [NBNode] { nodes(role: .dev) }

    var pending: [NBPeer] {
        (overview?.peers ?? []).filter { $0.groupNames.contains(Self.pendingGroup) }
    }

    var onlineCount: Int { (overview?.peers ?? []).filter(\.connected).count }

    private func nodes(role: NBGroupRole) -> [NBNode] {
        let names = roles.filter { $0.value == role }.map(\.key)
        let peers = overview?.peers ?? []
        return names
            .map { name in
                let member = peers.first { $0.groupNames.contains(name) }
                return NBNode(groupName: name, display: name, peer: member)
            }
            .sorted { $0.display < $1.display }
    }

    private var accessSet: Set<String> {
        Set((overview?.access ?? []).map { "\($0.sourceGroup)|\($0.destGroup)" })
    }

    func hasAccess(dev: String, server: String) -> Bool {
        accessSet.contains("\(dev)|\(server)")
    }

    private func policyID(src: String, dst: String) -> String? {
        (overview?.access ?? []).first { $0.sourceGroup == src && $0.destGroup == dst }?.policyId
    }

    /// The server-role group a peer belongs to, if any (for the terminal menu).
    func serverGroup(of peer: NBPeer) -> String? { peer.groupNames.first { roles[$0] == .server } }

    /// The dev-role group a peer belongs to, if any (for the support toggle).
    func devGroup(of peer: NBPeer) -> String? { peer.groupNames.first { roles[$0] == .dev } }

    /// The peer's group memberships, minus reserved groups (All / dev-pending).
    func memberGroups(of peer: NBPeer) -> [String] {
        peer.groupNames.filter { !Self.reservedGroups.contains($0) }
    }

    /// Server-role groups this peer can SSH into — derived from its group
    /// membership + the live policies (peer as source). Answers "máy này vào
    /// được server nào" for any machine, even if its group isn't tagged.
    func reachableServers(of peer: NBPeer) -> [String] {
        let mine = Set(peer.groupNames)
        var out: [String] = []
        for e in (overview?.access ?? []) where mine.contains(e.sourceGroup) && roles[e.destGroup] == .server {
            if !out.contains(e.destGroup) { out.append(e.destGroup) }
        }
        return out.sorted()
    }

    /// Dev-role groups that can SSH into this peer (peer as destination).
    /// Answers "server này được ai vào".
    func accessorsOf(_ peer: NBPeer) -> [String] {
        let mine = Set(peer.groupNames)
        var out: [String] = []
        for e in (overview?.access ?? []) where mine.contains(e.destGroup) && roles[e.sourceGroup] == .dev {
            if !out.contains(e.sourceGroup) { out.append(e.sourceGroup) }
        }
        return out.sorted()
    }

    /// Newest agent version seen across all peers — used to flag stale agents.
    var latestVersion: String {
        (overview?.peers ?? []).map(\.version).filter { !$0.isEmpty }.max() ?? ""
    }

    // MARK: load

    func start() {
        Task { await load() }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let status = try await client.netbirdConfigShow()
            configured = status.configured
            baseURL = status.baseURL
            guard configured else { overview = nil; return }
            overview = try await client.netbirdOverview()
            autoInferRolesIfNeeded()
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    // MARK: config

    func saveConfig(baseURL: String, token: String) async {
        busy = true
        defer { busy = false }
        do {
            try await client.netbirdConfigSet(baseURL: baseURL, token: token)
            await load()
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    // MARK: matrix grant/revoke

    func setAccess(dev: String, server: String, on: Bool) async {
        await mutate {
            if on {
                try await self.client.netbirdGrant(srcGroup: dev, dstGroup: server)
            } else if let pid = self.policyID(src: dev, dst: server) {
                try await self.client.netbirdRevoke(policyID: pid)
            }
        }
    }

    /// Remove every grant whose source is this dev group (kill switch).
    func revokeAllForDev(_ devGroup: String) async {
        await mutate {
            for edge in (self.overview?.access ?? []) where edge.sourceGroup == devGroup {
                try await self.client.netbirdRevoke(policyID: edge.policyId)
            }
        }
    }

    // MARK: reverse support (admin → dev)

    func reverseSupportEnabled(dev: String) -> Bool { hasAccess(dev: Self.adminGroup, server: dev) }

    func setReverseSupport(dev: String, on: Bool) async {
        await mutate {
            if on {
                try await self.client.netbirdGrant(srcGroup: Self.adminGroup, dstGroup: dev)
            } else if let pid = self.policyID(src: Self.adminGroup, dst: dev) {
                try await self.client.netbirdRevoke(policyID: pid)
            }
        }
    }

    // MARK: enrollment

    /// Single-use enrollment key (usageLimit defaults to 1 in the client → a
    /// one-off key). `name` carries the requester so the key is traceable in the
    /// setup-key list and the pending banner; 24h default expiry keeps an
    /// emailed key's exposure window short.
    func createSetupKey(name: String = "dev-enroll", expiresDays: Int = 1) async -> NBSetupKey? {
        busy = true
        defer { busy = false }
        do {
            return try await client.netbirdSetupKeyCreate(
                name: name, group: Self.pendingGroup, expiresDays: expiresDays)
        } catch {
            lastError = CswError.redact(error.localizedDescription)
            return nil
        }
    }

    /// Existing setup keys (metadata only). Populated on demand by the key
    /// management popover, not on every overview refresh.
    @Published private(set) var setupKeys: [NBSetupKeyInfo] = []

    func loadSetupKeys() async {
        do {
            setupKeys = try await client.netbirdSetupKeyList()
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Revokes a setup key so it can no longer enroll machines, then refreshes
    /// the list. Use to kill a leaked or finished key.
    func revokeSetupKey(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            try await client.netbirdSetupKeyRevoke(id: id)
            setupKeys = try await client.netbirdSetupKeyList()
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Approve a pending machine into a group (created if missing) and tag that
    /// group with `role` so it appears as the right matrix axis — dev (row) or
    /// server (column).
    func approve(peer: NBPeer, group: String, role: NBGroupRole = .dev) async {
        let name = group.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        setRole(role, for: name)
        await mutate { try await self.client.netbirdPeerAssign(peerID: peer.id, group: name) }
    }

    func reject(peer: NBPeer) async {
        await mutate { try await self.client.netbirdPeerDelete(peerID: peer.id) }
    }

    /// Removes a machine from NetBird entirely (not just from a group), then
    /// revokes every spent single-use key so the removed machine can't rejoin
    /// with the key it enrolled with. NetBird doesn't link a peer to its key, so
    /// we can't target just this machine's key — but a spent single-use key has
    /// already done its one job, so revoking all spent keys is safe (it never
    /// affects a machine that's already in the mesh) and matches "delete the
    /// machine → kill its key; reinstall needs a fresh key".
    func deletePeer(_ peer: NBPeer) async {
        busy = true
        defer { busy = false }
        do {
            try await client.netbirdPeerDelete(peerID: peer.id)
            await revokeSpentSetupKeys()
            overview = try await client.netbirdOverview()
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Best-effort revoke of keys that are already used up / expired (a
    /// single-use key after its one enrollment). Errors are swallowed so a
    /// stubborn key never blocks the delete that triggered this.
    private func revokeSpentSetupKeys() async {
        guard let keys = try? await client.netbirdSetupKeyList() else { return }
        for k in keys where !k.valid && !k.revoked {
            _ = try? await client.netbirdSetupKeyRevoke(id: k.id)
        }
    }

    // MARK: peer ↔ group membership

    /// All non-reserved groups, sorted — the choices in a machine's "add to
    /// group" menu. Includes both server- and dev-tagged groups plus untagged
    /// ones so a machine can be filed before its group gets a role.
    var assignableGroups: [NBGroup] {
        (overview?.groups ?? [])
            .filter { !Self.reservedGroups.contains($0.name) }
            .sorted { $0.name < $1.name }
    }

    /// Adds a machine to a group (does NOT change the group's server/dev role).
    func assignPeer(_ peer: NBPeer, toGroup group: String) async {
        let g = group.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else { return }
        await mutate { try await self.client.netbirdPeerAssign(peerID: peer.id, group: g) }
    }

    /// Removes a machine from a group (membership only).
    func removePeer(_ peer: NBPeer, fromGroup group: String) async {
        await mutate { try await self.client.netbirdPeerRemoveFromGroup(peerID: peer.id, group: group) }
    }

    // MARK: rename

    func renamePeer(_ peer: NBPeer, to name: String) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != peer.name else { return }
        await mutate { try await self.client.netbirdPeerRename(peerID: peer.id, name: n) }
    }

    /// Member machine names of a group (for hover tooltips on the matrix).
    func members(ofGroup name: String) -> [String] {
        guard let g = (overview?.groups ?? []).first(where: { $0.name == name }) else { return [] }
        return (g.peers ?? []).map(\.name).sorted()
    }

    func groupID(forName name: String) -> String? {
        (overview?.groups ?? []).first { $0.name == name }?.id
    }

    /// Rename a group given only its current name (matrix rows/cols hold names).
    func renameGroup(name oldName: String, to newName: String) async {
        guard let id = groupID(forName: oldName) else { return }
        await renameGroup(id: id, oldName: oldName, to: newName)
    }

    func renameGroup(id: String, oldName: String, to name: String) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != oldName else { return }
        // Migrate the local role tag so the matrix keeps classifying the group.
        if let r = roles[oldName] { roles[n] = r; roles.removeValue(forKey: oldName); NetbirdRolesStore.save(roles) }
        // Carry the accent color and markdown note across too — all three are
        // keyed by group name, so a rename would otherwise orphan them.
        if let c = colors[oldName] { colors[n] = c; colors.removeValue(forKey: oldName); NetbirdColorsStore.save(colors) }
        if let nt = notes[oldName] { notes[n] = nt; notes.removeValue(forKey: oldName); NetbirdNotesStore.save(notes) }
        await mutate { try await self.client.netbirdGroupRename(groupID: id, name: n) }
    }

    // MARK: create / delete group

    /// Creates an empty NetBird group and tags it `role` locally so it appears
    /// as a matrix row/col right away. The role tag is applied only after the
    /// server confirms the create, so a failed call never leaves a phantom row
    /// pointing at a group that doesn't exist.
    func createGroup(name: String, role: NBGroupRole) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.netbirdGroupCreate(name: n)
            setRole(role, for: n)
            overview = try await client.netbirdOverview()
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Deletes a group by its current name. NetBird blocks deletion while the
    /// group is still referenced by a policy / route / setup-key — that error
    /// surfaces in `lastError` and the local role/color tags are kept intact.
    /// Tags are cleared only after the server confirms the delete.
    func deleteGroup(name: String) async {
        guard let id = groupID(forName: name) else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.netbirdGroupDelete(groupID: id)
            setRole(nil, for: name)
            setColor(nil, for: name)
            overview = try await client.netbirdOverview()
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    // MARK: terminal

    /// Opens Terminal.app and runs `netbird ssh <user>@<host>` against a server.
    func openTerminal(user: String, host: String) {
        let cmd = "netbird ssh \(user)@\(host)"
        let script = "tell application \"Terminal\" to do script \"\(cmd)\"\ntell application \"Terminal\" to activate"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch { lastError = error.localizedDescription }
    }

    // MARK: helper

    private func mutate(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            overview = try await client.netbirdOverview()
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }
}
