import Foundation

/// Recursively reads `*.jsonl` files under `~/.claude/projects/`, decoding only
/// assistant-turn records relevant to the active 5h rate-limit window.
///
/// Optimizations vs naive full-scan:
///  - Skip files whose modification date is older than `recentHours` ago.
///  - Skip records with timestamp older than `recentHours` ago.
///  - Dedup by `(requestId, messageId)`.
///
/// On a 942-file / 441MB corpus this brings work down from ~all to ~tens of files.
enum JsonlUsageService {

    /// Default scan window — must be ≥ 5h to keep the active block + a small safety buffer.
    static let defaultRecentHours: TimeInterval = 6

    static var claudeProjectsRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func loadAllRecords(recentHours: TimeInterval = defaultRecentHours) -> [UsageRecord] {
        let fm = FileManager.default
        let root = claudeProjectsRoot
        guard fm.fileExists(atPath: root.path) else { return [] }

        let cutoff = Date().addingTimeInterval(-recentHours * 3600)

        var seen = Set<String>()
        var records: [UsageRecord] = []
        records.reserveCapacity(2048)

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // Skip files unchanged since cutoff.
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = values.contentModificationDate,
               mtime < cutoff {
                continue
            }
            parseFile(at: url, cutoff: cutoff, seen: &seen, into: &records)
        }

        records.sort { $0.timestamp < $1.timestamp }
        return records
    }

    private static func parseFile(
        at url: URL,
        cutoff: Date,
        seen: inout Set<String>,
        into records: inout [UsageRecord]
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                consume(lineData: lineData, cutoff: cutoff, seen: &seen, into: &records)
            }
        }
        if !buffer.isEmpty {
            consume(lineData: buffer, cutoff: cutoff, seen: &seen, into: &records)
        }
    }

    private static func consume(
        lineData: Data,
        cutoff: Date,
        seen: inout Set<String>,
        into records: inout [UsageRecord]
    ) {
        guard !lineData.isEmpty,
              let line = String(data: lineData, encoding: .utf8),
              !line.isEmpty,
              let rec = UsageRecordDecoder.decode(line: line) else {
            return
        }
        // Drop records older than the scan window.
        if rec.timestamp < cutoff { return }
        if seen.insert(rec.dedupKey).inserted {
            records.append(rec)
        }
    }
}
