import Foundation

/// One junk location (a cache/log/build-artifact directory) with its size.
struct JunkItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let label: String
    let category: String
    let safety: CleanupSafety
    var sizeBytes: Int64
}

/// Scans a curated set of safe-to-clear cache / log / build-artifact locations
/// (they all regenerate) and cleans the selected ones to the Trash.
@MainActor
final class JunkScanner: ObservableObject {
    @Published private(set) var items: [JunkItem] = []
    @Published private(set) var isScanning = false
    @Published var lastError: String?

    private let fm = FileManager.default

    /// (path relative to home, label, category, safety). Everything is a
    /// cache/log/derived dir that rebuilds; `caution` marks the few that hold
    /// window state or cost a noticeable re-download/re-index.
    private let targets: [(String, String, String, CleanupSafety)] = [
        ("Library/Caches", "Cache ứng dụng", "Cache", .safe),
        ("Library/Logs", "Log", "Log", .safe),
        ("Library/Saved Application State", "Trạng thái cửa sổ đã lưu", "State", .caution),
        ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData", "Xcode", .safe),
        ("Library/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport", "Xcode", .caution),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches", "Xcode", .safe),
        (".npm/_cacache", "npm cache", "Dev", .safe),
        (".cache", "~/.cache", "Dev", .caution),
        (".gradle/caches", "Gradle caches", "Dev", .safe),
        ("Library/Caches/Homebrew", "Homebrew cache", "Dev", .safe),
        ("Library/Caches/go-build", "Go build cache", "Dev", .safe),
        (".cocoapods/repos", "CocoaPods repos", "Dev", .caution),
        ("Library/Caches/pip", "pip cache", "Dev", .safe),
        (".bun/install/cache", "Bun cache", "Dev", .safe),
    ]

    var total: Int64 { items.map(\.sizeBytes).reduce(0, +) }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        items = []
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let targets = self.targets
        Task {
            var found: [JunkItem] = []
            for (rel, label, cat, safety) in targets {
                let url = home.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let size = await Task.detached { InstalledAppsStore.directorySize(url) }.value
                if size > 0 { found.append(JunkItem(url: url, label: label, category: cat, safety: safety, sizeBytes: size)) }
            }
            self.items = found.sorted { $0.sizeBytes > $1.sizeBytes }
            self.isScanning = false
        }
    }

    @discardableResult
    func clean(_ selected: [JunkItem]) async -> Int64 {
        var freed: Int64 = 0
        for it in selected {
            do { try fm.trashItem(at: it.url, resultingItemURL: nil); freed += it.sizeBytes }
            catch { lastError = "Không xoá được \(it.label): \(error.localizedDescription)" }
        }
        let ids = Set(selected.map(\.id))
        items.removeAll { ids.contains($0.id) }
        return freed
    }
}
