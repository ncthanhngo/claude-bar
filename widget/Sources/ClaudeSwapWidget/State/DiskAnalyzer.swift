import AppKit
import Foundation

/// A mounted volume with capacity, for the visual drive bars.
struct VolumeInfo: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let total: Int64
    let free: Int64
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// A top-level child directory with its computed size, for the breakdown bars.
struct DirUsage: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let sizeBytes: Int64
}

/// Lists mounted volumes (instant) and breaks a chosen folder into its biggest
/// top-level children (background scan). Read-only — no deletion here.
@MainActor
final class DiskAnalyzer: ObservableObject {
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var dirs: [DirUsage] = []
    @Published var rootPath: String = NSHomeDirectory()
    @Published private(set) var isScanning = false

    /// Deep scan: largest directories at ANY depth under rootPath (vs `dirs`
    /// which is one level). `deepMode` toggles which list the UI shows.
    @Published var deepMode = false
    @Published private(set) var deepDirs: [DirUsage] = []
    @Published private(set) var isDeepScanning = false

    func loadVolumes() {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey]
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                              options: [.skipHiddenVolumes]) else { return }
        var out: [VolumeInfo] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: keys), v.volumeIsBrowsable == true else { continue }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }
            out.append(VolumeInfo(name: v.volumeName ?? u.lastPathComponent, path: u.path,
                                  total: total, free: Int64(v.volumeAvailableCapacityForImportantUsage ?? 0)))
        }
        volumes = out.sorted { $0.total > $1.total }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: rootPath)
        if p.runModal() == .OK, let u = p.url { rootPath = u.path; rescan() }
    }

    /// Run whichever scan the current mode wants. The toolbar's ↻ calls this.
    func rescan() { deepMode ? deepScan() : scanDirs() }

    func scanDirs() {
        guard !isScanning else { return }
        isScanning = true
        dirs = []
        let root = URL(fileURLWithPath: rootPath)
        Task {
            let res = await Task.detached { DiskAnalyzer.topChildren(root) }.value
            self.dirs = res
            self.isScanning = false
        }
    }

    func deepScan() {
        guard !isDeepScanning else { return }
        isDeepScanning = true
        deepDirs = []
        let root = URL(fileURLWithPath: rootPath)
        Task {
            let res = await Task.detached { DiskAnalyzer.largestDirs(under: root) }.value
            self.deepDirs = res
            self.isDeepScanning = false
        }
    }

    /// Walks the whole subtree ONCE, bottom-up, summing each directory's total
    /// size as it unwinds — so every folder is sized in a single pass (no
    /// repeated re-walking). Returns the biggest folders at any depth, the ones
    /// worth a cleanup look. Skips hidden entries and symlinks (no cycles, no
    /// double-counting) and prunes anything under `minBytes` so the list stays
    /// signal. The root itself is dropped (it's just the sum of everything).
    nonisolated static func largestDirs(under root: URL,
                                        minBytes: Int64 = 50 * 1024 * 1024,
                                        limit: Int = 40) -> [DirUsage] {
        var found: [DirUsage] = []
        _ = accumulate(root, minBytes: minBytes, into: &found)
        return Array(found.filter { $0.url.path != root.path }
            .sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit))
    }

    private nonisolated static func accumulate(_ dir: URL, minBytes: Int64,
                                               into found: inout [DirUsage]) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let items = try? fm.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for u in items {
            let v = try? u.resourceValues(forKeys: keys)
            if v?.isSymbolicLink == true { continue }
            if v?.isDirectory == true {
                total += accumulate(u, minBytes: minBytes, into: &found)
            } else {
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
        }
        if total >= minBytes { found.append(DirUsage(url: dir, sizeBytes: total)) }
        return total
    }

    nonisolated static func topChildren(_ root: URL) -> [DirUsage] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [DirUsage] = []
        for u in items {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let size = isDir ? InstalledAppsStore.directorySize(u)
                : Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            if size > 0 { out.append(DirUsage(url: u, sizeBytes: size)) }
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
