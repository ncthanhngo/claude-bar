import Foundation

/// Drives the Backup & Restore Tools page. Wraps CswClient backup calls, holds
/// the profile list + the in-edit draft, and surfaces busy/error state for the
/// UI. All server-mutating calls (install/run/restore/createRemote) are invoked
/// only after the view shows its confirm sheet.
@MainActor
final class BackupRestoreStore: ObservableObject {

    enum Busy: Equatable {
        case loading, saving, preflight, installing, running, restoring, rclone, snapshots
    }

    @Published var profiles: [BackupProfile] = []
    @Published var hosts: [CswClient.SSHHostDTO] = []
    @Published var draft: BackupProfile?          // currently edited profile (nil = nothing selected)
    @Published var preflight: BackupPreflight?
    @Published var recentRuns: [BackupStatus] = []
    @Published var snapshots: BackupSnapshotList?
    @Published var busy: Busy?
    @Published var lastError: String?
    @Published var consoleOutput: String = ""     // stdout/stderr from run/restore/rclone

    private let client: CswClient

    init(client: CswClient = CswClient()) { self.client = client }

    var selectedID: String? { draft?.id.isEmpty == false ? draft?.id : nil }
    var isDirtyNew: Bool { draft?.id.isEmpty == true }

    // MARK: load / selection

    func load() async {
        busy = .loading; defer { busy = nil }
        do {
            async let p = client.backupList()
            async let h = client.sshList()
            profiles = try await p
            hosts = try await h.sorted { $0.name < $1.name }
            lastError = nil
            // Keep the current selection if it still exists.
            if let id = draft?.id, !id.isEmpty, let fresh = profiles.first(where: { $0.id == id }) {
                draft = fresh
            }
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    func select(_ profile: BackupProfile) {
        draft = profile
        preflight = nil; recentRuns = []; snapshots = nil; consoleOutput = ""
    }

    func newProfile() {
        var p = BackupProfile()
        p.sources = [BackupSource(kind: .command, name: "db")]
        if let firstHost = hosts.first?.name { p.sshHost = firstHost }
        draft = p
        preflight = nil; recentRuns = []; snapshots = nil; consoleOutput = ""
    }

    // MARK: persistence

    func save() async {
        guard let p = draft else { return }
        busy = .saving; defer { busy = nil }
        do {
            let saved = try await client.backupSave(p)
            draft = saved
            await load()
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    func remove(_ id: String) async {
        busy = .loading; defer { busy = nil }
        do {
            try await client.backupRemove(id: id)
            if draft?.id == id { draft = nil }
            await load()
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    // MARK: server ops (read)

    func runPreflight() async {
        guard let id = selectedID else { return }
        busy = .preflight; defer { busy = nil }
        do { preflight = try await client.backupPreflight(id: id); lastError = nil }
        catch { lastError = CswError.redact(error.localizedDescription) }
    }

    func refreshStatus() async {
        guard let id = selectedID else { return }
        do { recentRuns = try await client.backupStatus(id: id).reversed() }
        catch { lastError = CswError.redact(error.localizedDescription) }
    }

    func loadSnapshots() async {
        guard let id = selectedID else { return }
        busy = .snapshots; defer { busy = nil }
        do { snapshots = try await client.backupSnapshots(id: id); lastError = nil }
        catch { lastError = CswError.redact(error.localizedDescription) }
    }

    func generate() async -> BackupArtifacts? {
        guard let id = selectedID else { return nil }
        do { return try await client.backupGenerate(id: id) }
        catch { lastError = CswError.redact(error.localizedDescription); return nil }
    }

    // MARK: server ops (mutating — call only after confirm)

    func install() async {
        guard let id = selectedID else { return }
        busy = .installing; defer { busy = nil }
        do { try await client.backupInstall(id: id); await load(); lastError = nil }
        catch { lastError = CswError.redact(error.localizedDescription) }
    }

    func uninstall() async {
        guard let id = selectedID else { return }
        busy = .installing; defer { busy = nil }
        do { try await client.backupUninstall(id: id); await load(); lastError = nil }
        catch { lastError = CswError.redact(error.localizedDescription) }
    }

    func runNow() async {
        guard let id = selectedID else { return }
        busy = .running; defer { busy = nil }
        do {
            let res = try await client.backupRunNow(id: id)
            consoleOutput = res.stdout + (res.stderr.isEmpty ? "" : "\n--- stderr ---\n" + res.stderr)
            await refreshStatus()
            lastError = res.exitCode == 0 ? nil : "Backup thoát với mã \(res.exitCode)"
        } catch { lastError = CswError.redact(error.localizedDescription) }
    }

    func restore(snapshot: String) async {
        guard let id = selectedID else { return }
        busy = .restoring; defer { busy = nil }
        do {
            let res = try await client.backupRestore(id: id, snapshot: snapshot)
            consoleOutput = res.stdout + (res.stderr.isEmpty ? "" : "\n--- stderr ---\n" + res.stderr)
            lastError = res.exitCode == 0 ? nil : "Khôi phục thoát với mã \(res.exitCode)"
        } catch { lastError = CswError.redact(error.localizedDescription) }
    }

    // MARK: rclone guided setup

    func listDrives(tokenJSON: String) async -> String {
        guard let id = selectedID else { return "" }
        busy = .rclone; defer { busy = nil }
        do {
            let res = try await client.backupRcloneListDrives(id: id, tokenJSON: tokenJSON)
            consoleOutput = res.stdout + res.stderr
            lastError = nil
            return res.stdout
        } catch { lastError = CswError.redact(error.localizedDescription); return "" }
    }

    func createRemote(remote: String, driveID: String, tokenJSON: String) async {
        guard let id = selectedID else { return }
        busy = .rclone; defer { busy = nil }
        do {
            let res = try await client.backupRcloneCreateRemote(id: id, remote: remote, driveID: driveID, tokenJSON: tokenJSON)
            consoleOutput = res.stdout + res.stderr
            lastError = res.exitCode == 0 ? nil : "rclone config thoát với mã \(res.exitCode)"
            await runPreflight()
        } catch { lastError = CswError.redact(error.localizedDescription) }
    }
}
