import Foundation

/// Backup & Restore backend calls. Mirrors `csw backup …`. Read commands decode
/// JSON; mutating commands (save/install/run/restore/uninstall/rclone-*) are
/// only ever invoked after the UI confirm sheet, same trust model as `csw ssh`.
extension CswClient {

    /// ISO8601 dates so Go's time.Time (RFC3339) round-trips on save.
    private static let profileEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func backupList() async throws -> [BackupProfile] {
        try await run(["backup", "list"], decode: [BackupProfile].self)
    }

    @discardableResult
    func backupSave(_ profile: BackupProfile) async throws -> BackupProfile {
        let data = try CswClient.profileEncoder.encode(profile)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return try await runWithStdin(["backup", "save"], stdin: json, decode: BackupProfile.self)
    }

    func backupRemove(id: String) async throws {
        _ = try await runRaw(["backup", "remove", "--id", id])
    }

    func backupGenerate(id: String) async throws -> BackupArtifacts {
        try await run(["backup", "generate", "--id", id], decode: BackupArtifacts.self)
    }

    func backupPreflight(id: String) async throws -> BackupPreflight {
        try await run(["backup", "preflight", "--id", id], decode: BackupPreflight.self)
    }

    func backupInstall(id: String) async throws {
        _ = try await runRaw(["backup", "install", "--id", id])
    }

    func backupUninstall(id: String) async throws {
        _ = try await runRaw(["backup", "uninstall", "--id", id])
    }

    func backupRunNow(id: String) async throws -> BackupRunResult {
        try await run(["backup", "run", "--id", id], decode: BackupRunResult.self)
    }

    func backupStatus(id: String) async throws -> [BackupStatus] {
        try await run(["backup", "status", "--id", id], decode: [BackupStatus].self)
    }

    func backupSnapshots(id: String) async throws -> BackupSnapshotList {
        try await run(["backup", "snapshots", "--id", id], decode: BackupSnapshotList.self)
    }

    func backupRestore(id: String, snapshot: String) async throws -> BackupRunResult {
        try await run(["backup", "restore", "--id", id, "--snapshot", snapshot], decode: BackupRunResult.self)
    }

    /// List SharePoint drives reachable with an rclone OAuth token (token on stdin).
    func backupRcloneListDrives(id: String, tokenJSON: String) async throws -> BackupRunResult {
        try await runWithStdin(["backup", "rclone-list-drives", "--id", id], stdin: tokenJSON, decode: BackupRunResult.self)
    }

    /// Create the named rclone remote on the server (token on stdin).
    func backupRcloneCreateRemote(id: String, remote: String, driveID: String, tokenJSON: String) async throws -> BackupRunResult {
        try await runWithStdin(
            ["backup", "rclone-create-remote", "--id", id, "--remote", remote, "--drive-id", driveID],
            stdin: tokenJSON, decode: BackupRunResult.self)
    }
}
