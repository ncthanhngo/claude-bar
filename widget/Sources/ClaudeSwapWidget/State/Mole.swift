import Foundation
import SwiftUI

/// Integration with **mole** (`mo`) — the scan/analysis engine behind the App
/// tools (disk · large files · junk · health). GUI apps don't inherit the shell
/// `PATH`, so we probe the absolute install locations mole uses: `install.sh`
/// drops binaries in `/usr/local/bin`, Homebrew in `/opt/homebrew/bin`.
///
/// Only the read-only, machine-readable commands are used here:
/// `mo analyze --json [<path>]` and `mo status --json`. Destructive commands
/// (clean/uninstall/optimize) stay native so the app keeps its "move to Trash,
/// recoverable, never hard-delete" guarantee.
enum Mole {
    static let binaryCandidates = [
        "/usr/local/bin/mo", "/opt/homebrew/bin/mo",
        "/usr/local/bin/mole", "/opt/homebrew/bin/mole",
    ]

    /// First installed `mo`/`mole` binary, or nil when not installed.
    static func binaryPath() -> String? {
        binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { binaryPath() != nil }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `mo analyze --json [<path>]` — omitting the path yields **overview** mode
    /// (home + insights, with `cleanable` flags); a path scans that directory's
    /// immediate children plus its largest files.
    static func analyze(path: String?) throws -> AnalyzeResult {
        var args = ["analyze", "--json"]
        if let path, !path.isEmpty { args.append(path) }
        return try runJSON(args, as: AnalyzeResult.self)
    }

    /// `mo status --json` — one-shot system metrics + 0–100 health score.
    static func status() throws -> StatusSnapshot {
        try runJSON(["status", "--json"], as: StatusSnapshot.self)
    }

    private static func runJSON<T: Decodable>(_ args: [String], as _: T.Type) throws -> T {
        guard let bin = binaryPath() else { throw Failure(message: "Chưa cài mole (mo).") }
        let out = Shell.run(bin, args)
        guard let data = out.data(using: .utf8), !data.isEmpty else {
            throw Failure(message: "mole không trả dữ liệu.")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw Failure(message: "Không đọc được JSON của mole: \(error.localizedDescription)") }
    }
}

// MARK: - `mo analyze --json` models

/// Result of `mo analyze --json`. `large_files` and `total_files` are omitted in
/// overview mode, so both are optional-with-default.
struct AnalyzeResult: Decodable {
    let path: String
    let overview: Bool
    let entries: [AnalyzeEntry]
    let largeFiles: [AnalyzeFile]
    let totalSize: Int64

    enum CodingKeys: String, CodingKey {
        case path, overview, entries
        case largeFiles = "large_files"
        case totalSize = "total_size"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        overview = try c.decodeIfPresent(Bool.self, forKey: .overview) ?? false
        entries = try c.decodeIfPresent([AnalyzeEntry].self, forKey: .entries) ?? []
        largeFiles = try c.decodeIfPresent([AnalyzeFile].self, forKey: .largeFiles) ?? []
        totalSize = try c.decodeIfPresent(Int64.self, forKey: .totalSize) ?? 0
    }
}

/// One directory/file entry. `cleanable` marks entries mole considers safe to
/// clear (cache/log/build-artifact); `is_dir` distinguishes folders from files.
struct AnalyzeEntry: Decodable {
    let name: String
    let path: String
    let size: Int64
    let isDir: Bool
    let cleanable: Bool

    enum CodingKeys: String, CodingKey {
        case name, path, size, cleanable
        case isDir = "is_dir"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        isDir = try c.decodeIfPresent(Bool.self, forKey: .isDir) ?? false
        cleanable = try c.decodeIfPresent(Bool.self, forKey: .cleanable) ?? false
    }
}

struct AnalyzeFile: Decodable {
    let name: String
    let path: String
    let size: Int64
}

// MARK: - `mo status --json` models (subset actually shown)

/// Subset of mole's `MetricsSnapshot` the health view renders. Every field is
/// tolerant of absence so a schema change in mole degrades gracefully rather
/// than failing the whole decode.
struct StatusSnapshot: Decodable {
    let healthScore: Int
    let healthScoreMsg: String?
    let uptime: String?
    let hardware: Hardware?
    let memory: Memory?
    let cpu: CPU?

    struct Hardware: Decodable {
        let model: String?
        let cpuModel: String?
        let totalRAM: String?
        let osVersion: String?
        enum CodingKeys: String, CodingKey {
            case model
            case cpuModel = "cpu_model"
            case totalRAM = "total_ram"
            case osVersion = "os_version"
        }
    }

    struct Memory: Decodable {
        let used: UInt64?
        let total: UInt64?
        let usedPercent: Double?
        let swapUsed: UInt64?
        enum CodingKeys: String, CodingKey {
            case used, total
            case usedPercent = "used_percent"
            case swapUsed = "swap_used"
        }
    }

    struct CPU: Decodable {
        let usage: Double?
        let load1: Double?
    }

    enum CodingKeys: String, CodingKey {
        case healthScore = "health_score"
        case healthScoreMsg = "health_score_msg"
        case uptime, hardware, memory, cpu
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        healthScore = try c.decodeIfPresent(Int.self, forKey: .healthScore) ?? 0
        healthScoreMsg = try c.decodeIfPresent(String.self, forKey: .healthScoreMsg)
        uptime = try c.decodeIfPresent(String.self, forKey: .uptime)
        hardware = try c.decodeIfPresent(Hardware.self, forKey: .hardware)
        memory = try c.decodeIfPresent(Memory.self, forKey: .memory)
        cpu = try c.decodeIfPresent(CPU.self, forKey: .cpu)
    }
}

// MARK: - installer

/// Tracks whether `mo` is installed and runs mole's official `install.sh` on
/// demand. `/usr/local/bin` needs admin, so the whole `curl | bash` runs once
/// under a single macOS admin prompt (osascript). No binary is bundled — this
/// keeps the GPL-3.0 tool out of the app archive.
@MainActor
final class MoleInstaller: ObservableObject {
    static let shared = MoleInstaller()

    @Published private(set) var installed: Bool
    @Published private(set) var installing = false
    @Published var lastError: String?

    private init() { installed = Mole.isInstalled }

    /// Re-probe the filesystem (call after an install attempt or on appear).
    func refresh() { installed = Mole.isInstalled }

    func install() {
        guard !installing else { return }
        installing = true
        lastError = nil
        Task {
            let cmd = "/usr/bin/curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | /bin/bash"
            let ok = await Task.detached { Shell.admin(cmd) }.value
            self.installing = false
            self.refresh()
            if !self.installed {
                self.lastError = ok
                    ? "Cài xong nhưng chưa thấy mo — thử mở lại app hoặc kiểm tra mạng."
                    : "Cài mole thất bại hoặc bị huỷ."
            }
        }
    }
}
