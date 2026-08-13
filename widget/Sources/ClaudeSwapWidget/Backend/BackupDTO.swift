import Foundation

/// Swift mirrors of the Go `backup` package JSON shapes. Keys match the Go
/// struct tags exactly (camelCase) so the shared CswClient decoder round-trips
/// without a snake_case strategy. Array fields are non-optional: the backend
/// always emits [] (never null) so decoding never trips on missing arrays.

enum BackupSourceKind: String, Codable, CaseIterable, Identifiable {
    case command, path, volume
    var id: String { rawValue }
    var label: String {
        switch self {
        case .command: return "Lệnh dump"
        case .path:    return "Thư mục / file"
        case .volume:  return "Docker volume"
        }
    }
}

struct BackupSource: Codable, Identifiable, Equatable {
    var kind: BackupSourceKind
    var name: String
    var dumpCmd: String?
    var restoreCmd: String?
    var paths: [String]
    var volumes: [String]

    // Local-only stable id for SwiftUI ForEach (not sent/decoded).
    var localID = UUID()
    var id: UUID { localID }

    enum CodingKeys: String, CodingKey { case kind, name, dumpCmd, restoreCmd, paths, volumes }

    init(kind: BackupSourceKind = .command, name: String = "",
         dumpCmd: String? = nil, restoreCmd: String? = nil,
         paths: [String] = [], volumes: [String] = []) {
        self.kind = kind; self.name = name
        self.dumpCmd = dumpCmd; self.restoreCmd = restoreCmd
        self.paths = paths; self.volumes = volumes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(BackupSourceKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        dumpCmd = try c.decodeIfPresent(String.self, forKey: .dumpCmd)
        restoreCmd = try c.decodeIfPresent(String.self, forKey: .restoreCmd)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        volumes = try c.decodeIfPresent([String].self, forKey: .volumes) ?? []
        localID = UUID()
    }
}

struct BackupRetention: Codable, Equatable {
    var daily: Int
    var weekly: Int
    var monthly: Int
    var yearly: Int

    static let `default` = BackupRetention(daily: 7, weekly: 4, monthly: 12, yearly: 3)
}

struct BackupSchedule: Codable, Equatable {
    var timeOfDay: String   // "HH:MM"
    var mechanism: String   // "cron" | "systemd"

    static let `default` = BackupSchedule(timeOfDay: "02:30", mechanism: "cron")
}

struct BackupProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var sshHost: String
    var sources: [BackupSource]
    var workDir: String
    var rcloneRemote: String
    var retention: BackupRetention
    var schedule: BackupSchedule
    var createdAt: Date?
    var updatedAt: Date?
    var lastInstalledAt: Date?

    init(id: String = "", name: String = "", sshHost: String = "",
         sources: [BackupSource] = [], workDir: String = "", rcloneRemote: String = "",
         retention: BackupRetention = .default, schedule: BackupSchedule = .default) {
        self.id = id; self.name = name; self.sshHost = sshHost
        self.sources = sources; self.workDir = workDir; self.rcloneRemote = rcloneRemote
        self.retention = retention; self.schedule = schedule
    }
}

struct BackupCheck: Codable, Identifiable, Equatable {
    let name: String
    let ok: Bool
    let detail: String
    var id: String { name }
}

struct BackupPreflight: Codable, Equatable {
    let checks: [BackupCheck]
    let ready: Bool
}

struct BackupStatus: Codable, Identifiable, Equatable {
    let ts: String
    let ok: Bool
    var stamp: String?
    var bytes: Int64?
    var durationMs: Int64?
    var stage: String?
    var error: String?
    var id: String { ts + (stamp ?? "") }
}

struct BackupSnapshotList: Codable, Equatable {
    var daily: [String]
    var weekly: [String]
    var monthly: [String]
    var yearly: [String]

    /// Flattened "tier/file" entries for a picker.
    var allPaths: [String] {
        daily.map { "daily/\($0)" } + weekly.map { "weekly/\($0)" }
            + monthly.map { "monthly/\($0)" } + yearly.map { "yearly/\($0)" }
    }
    var isEmpty: Bool { daily.isEmpty && weekly.isEmpty && monthly.isEmpty && yearly.isEmpty }
}

struct BackupRunResult: Codable, Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int
    let durationMs: Int64
    var status: BackupStatus?
}

struct BackupArtifacts: Codable, Equatable {
    let backupScript: String
    let restoreScript: String
    let cronLine: String
    var serviceUnit: String
    var timerUnit: String
    let installDir: String
    let mechanism: String
}
