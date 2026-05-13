import Foundation

/// Single unified view of "how much have I used right now" that the UI
/// consumes. Built by combining whichever data sources are available, in
/// preference order: web (ground truth) > calibrated JSONL > heuristic JSONL.
struct UsageSnapshot {
    /// Session (5-hour rate-limit window) percent used, 0-100.
    let sessionPercent: Double
    /// When the session window resets.
    let sessionResetsAt: Date?
    /// Optional weekly bar (only when web data available).
    let weeklyPercent: Double?
    let weeklyResetsAt: Date?
    /// Where the data came from — surfaced to the UI for transparency.
    let source: Source
    /// Auxiliary stats from the JSONL block (always available when there's an active block).
    let blockTokens: Int
    let messageCount: Int
    let blockStart: Date?
    let blockEnd: Date?

    enum Source: String, Equatable {
        case web        = "claude.ai"
        case jsonl      = "JSONL"
        case empty      = "—"
    }

    static let empty = UsageSnapshot(
        sessionPercent: 0, sessionResetsAt: nil,
        weeklyPercent: nil, weeklyResetsAt: nil,
        source: .empty,
        blockTokens: 0, messageCount: 0,
        blockStart: nil, blockEnd: nil
    )

    /// Seconds remaining until the session window resets. Falls back to the
    /// JSONL block end when web data lacks a `resets_at`.
    var sessionRemaining: TimeInterval {
        if let r = sessionResetsAt { return max(0, r.timeIntervalSinceNow) }
        if let e = blockEnd        { return max(0, e.timeIntervalSinceNow) }
        return 0
    }

    var isLive: Bool { source == .web }
}
