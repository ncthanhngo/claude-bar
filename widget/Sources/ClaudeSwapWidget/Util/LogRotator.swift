import Foundation

/// Size-based plain-text log rotation. Single active file plus up to N
/// archives (`.1`..`.N`). Rotation runs synchronously on demand; the caller
/// (DiagnosticsLogger's serial queue) ensures only one rotation at a time.
enum LogRotator {
    static let maxBytes: UInt64 = 5 * 1024 * 1024   // 5 MB
    static let archiveCount = 3

    /// If `path` is over the size threshold, shift `path` -> `path.1`,
    /// `path.1` -> `path.2`, …, dropping the oldest. Safe to call before
    /// every open; cheap when below threshold (just one stat call).
    static func rotateIfNeeded(at path: String) {
        guard let size = fileSize(path), size >= maxBytes else { return }
        rotate(path: path)
    }

    private static func fileSize(_ path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return nil }
        return size
    }

    private static func rotate(path: String) {
        let fm = FileManager.default
        // Delete the oldest archive first so the rename chain has room.
        let oldest = "\(path).\(archiveCount)"
        try? fm.removeItem(atPath: oldest)
        // Shift archives backward: .2 -> .3, .1 -> .2, etc.
        for i in stride(from: archiveCount - 1, through: 1, by: -1) {
            let src = "\(path).\(i)"
            let dst = "\(path).\(i + 1)"
            if fm.fileExists(atPath: src) {
                try? fm.moveItem(atPath: src, toPath: dst)
            }
        }
        // Move active log to .1
        if fm.fileExists(atPath: path) {
            try? fm.moveItem(atPath: path, toPath: "\(path).1")
        }
    }
}
