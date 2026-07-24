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

    var total: Int64 { items.map(\.sizeBytes).reduce(0, +) }

    /// `mo analyze --json` (overview mode) surfaces the entries mole marks
    /// `cleanable` — its curated cache/log/build-artifact set, richer than a
    /// hardcoded list. Discovery is mole's; the actual removal below stays
    /// native (Trash, recoverable).
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        items = []
        Task {
            let found = await Task.detached { JunkScanner.moleJunk() }.value
            self.items = found.sorted { $0.sizeBytes > $1.sizeBytes }
            self.isScanning = false
        }
    }

    nonisolated static func moleJunk() -> [JunkItem] {
        guard let r = try? Mole.analyze(path: nil) else { return [] }
        return r.entries
            .filter { $0.cleanable && $0.size > 0 }
            .map { JunkItem(url: URL(fileURLWithPath: $0.path), label: $0.name,
                            category: "mole", safety: .safe, sizeBytes: $0.size) }
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
