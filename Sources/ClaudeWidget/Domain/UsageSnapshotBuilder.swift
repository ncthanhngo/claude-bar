import Foundation

/// Composes data from multiple sources into the single `UsageSnapshot` the UI binds to.
enum UsageSnapshotBuilder {

    /// Preference: web > JSONL block.
    static func build(
        web: WebUsageService.Snapshot?,
        jsonlBlock: SessionBlock?,
        fallbackLimit: Int
    ) -> UsageSnapshot {
        if let web {
            return UsageSnapshot(
                sessionPercent: web.sessionUtilization,
                sessionResetsAt: web.sessionResetsAt,
                weeklyPercent: web.weeklyUtilization,
                weeklyResetsAt: web.weeklyResetsAt,
                source: .web,
                blockTokens: jsonlBlock?.totalTokens ?? 0,
                messageCount: jsonlBlock?.messageCount ?? 0,
                blockStart: jsonlBlock?.startTime,
                blockEnd: jsonlBlock?.endTime
            )
        }
        guard let block = jsonlBlock else { return .empty }
        let pct = fallbackLimit > 0
            ? min(100, (Double(block.totalTokens) / Double(fallbackLimit)) * 100.0)
            : 0
        return UsageSnapshot(
            sessionPercent: pct,
            sessionResetsAt: block.endTime,
            weeklyPercent: nil,
            weeklyResetsAt: nil,
            source: .jsonl,
            blockTokens: block.totalTokens,
            messageCount: block.messageCount,
            blockStart: block.startTime,
            blockEnd: block.endTime
        )
    }
}
