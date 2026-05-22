import Foundation

/// In-memory cache for decrypted attachment bytes. Keyed by attachment ID,
/// capped at 64 MB total. Designed for the historical-attachment preview
/// flow: scrolling to a 3-day-old message, clicking the chip, and seeing
/// the image without re-decoding every time. Bytes are never persisted —
/// purged on account switch via `clear()` from ChatStore.
@MainActor
final class AttachmentPreviewCache {
    static let shared = AttachmentPreviewCache()

    private let cache = NSCache<NSString, NSData>()

    private init() {
        // Cost is per-entry byte count; total cap 64 MB. NSCache evicts
        // oldest entries to stay under the limit.
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 256
    }

    func read(_ id: String) -> Data? {
        guard let nsdata = cache.object(forKey: id as NSString) else { return nil }
        return nsdata as Data
    }

    func write(_ id: String, data: Data) {
        cache.setObject(data as NSData, forKey: id as NSString, cost: data.count)
    }

    func clear() {
        cache.removeAllObjects()
    }
}
