import AppKit
import Foundation

/// One large file found by the scanner.
struct LargeFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let sizeBytes: Int64
    let modified: Date?

    /// Heuristic: junk/regenerable paths and re-downloadable installers are safe
    /// to trash; anything else is the user's own data and gets a caution badge.
    var safety: CleanupSafety {
        let p = url.path.lowercased()
        let junkHints = ["/caches/", "/cache/", "deriveddata", "/node_modules/",
                         "/.trash/", "/logs/", "/tmp/", "/library/developer/", "/.gradle/"]
        if junkHints.contains(where: p.contains) { return .safe }
        let installer: Set<String> = ["dmg", "pkg", "ipsw", "iso", "xip"]
        if installer.contains(url.pathExtension.lowercased()), p.contains("/downloads/") { return .safe }
        return .caution
    }
}

/// Walks a chosen folder for files at or above a size threshold and keeps the
/// largest ones, so the user can trash space hogs. Trash (recoverable).
@MainActor
final class LargeFilesScanner: ObservableObject {
    @Published private(set) var files: [LargeFile] = []
    @Published private(set) var isScanning = false
    @Published var rootPath: String = NSHomeDirectory()
    @Published var minMB: Int = 100
    @Published var lastError: String?

    private let fm = FileManager.default

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: rootPath)
        if p.runModal() == .OK, let u = p.url { rootPath = u.path }
    }

    /// `mo analyze --json <root>` returns the folder's largest files — mole is
    /// the engine. The `≥ minMB` stepper is applied client-side so the existing
    /// threshold UI still filters the result.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        files = []
        let root = rootPath
        let minBytes = Int64(minMB) * 1_048_576
        Task {
            let found = await Task.detached { LargeFilesScanner.moleLargeFiles(root, minBytes: minBytes) }.value
            self.files = found
            self.isScanning = false
        }
    }

    nonisolated static func moleLargeFiles(_ path: String, minBytes: Int64) -> [LargeFile] {
        guard let r = try? Mole.analyze(path: path) else { return [] }
        return Array(r.largeFiles
            .filter { $0.size >= minBytes }
            .sorted { $0.size > $1.size }
            .prefix(300)
            .map { LargeFile(url: URL(fileURLWithPath: $0.path), sizeBytes: $0.size, modified: nil) })
    }

    @discardableResult
    func trash(_ selected: [LargeFile]) async -> Int64 {
        var freed: Int64 = 0
        for f in selected {
            do { try fm.trashItem(at: f.url, resultingItemURL: nil); freed += f.sizeBytes }
            catch { lastError = "Không xoá được \(f.url.lastPathComponent): \(error.localizedDescription)" }
        }
        let ids = Set(selected.map(\.id))
        files.removeAll { ids.contains($0.id) }
        return freed
    }
}
