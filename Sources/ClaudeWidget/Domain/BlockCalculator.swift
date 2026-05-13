import Foundation

/// Group `UsageRecord`s into 5-hour session blocks (ccusage-compatible).
///
/// Rules:
///  - Records are sorted ascending by timestamp.
///  - First record starts a block; block.startTime = floor(record.timestamp, hour).
///  - A record falling inside `[startTime, startTime + 5h)` belongs to that block.
///  - A record outside opens a new block (start = floor of its hour).
enum BlockCalculator {

    static func computeBlocks(from records: [UsageRecord]) -> [SessionBlock] {
        guard !records.isEmpty else { return [] }

        var blocks: [SessionBlock] = []
        var current: SessionBlock?

        for rec in records {
            if var block = current, rec.timestamp < block.endTime {
                accumulate(&block, with: rec)
                current = block
            } else {
                if let finished = current {
                    blocks.append(finished)
                }
                current = newBlock(startingAt: rec)
            }
        }
        if let last = current { blocks.append(last) }
        return blocks
    }

    static func activeBlock(in blocks: [SessionBlock]) -> SessionBlock? {
        // Latest block whose window still includes "now".
        blocks.reversed().first { $0.isActive }
    }

    // MARK: - Helpers

    private static func newBlock(startingAt rec: UsageRecord) -> SessionBlock {
        let start = floorToHour(rec.timestamp)
        let end = start.addingTimeInterval(SessionBlock.blockDuration)
        var block = SessionBlock(
            startTime: start,
            endTime: end,
            totalTokens: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            messageCount: 0,
            models: []
        )
        accumulate(&block, with: rec)
        return block
    }

    private static func accumulate(_ block: inout SessionBlock, with rec: UsageRecord) {
        block.inputTokens += rec.inputTokens
        block.outputTokens += rec.outputTokens
        block.cacheCreationTokens += rec.cacheCreationTokens
        block.cacheReadTokens += rec.cacheReadTokens
        block.totalTokens += rec.totalTokens
        block.messageCount += 1
        if let m = rec.model { block.models.insert(m) }
    }

    private static func floorToHour(_ date: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return cal.date(from: comps) ?? date
    }
}
