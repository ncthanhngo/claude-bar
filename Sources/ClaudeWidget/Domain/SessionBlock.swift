import Foundation

/// A 5-hour rate-limit window, ccusage-compatible.
struct SessionBlock: Identifiable {
    let id = UUID()
    let startTime: Date
    let endTime: Date
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var messageCount: Int
    var models: Set<String>

    var isActive: Bool { Date() < endTime }

    /// Seconds remaining; clamped at 0.
    var remaining: TimeInterval {
        max(0, endTime.timeIntervalSinceNow)
    }
}

extension SessionBlock {
    static let blockDurationHours = 5
    static var blockDuration: TimeInterval { TimeInterval(blockDurationHours * 3600) }
}
