import Foundation

/// Mirrors backend/internal/usecase/briefing/types.go.
/// Mockup section reference: daily-briefing-preview.html.

/// Daily briefing payload returned by `csw briefing run|show --json`.
struct BriefingDTO: Codable, Hashable {
    let schemaVersion: Int
    let date: String                // "2026-05-21"
    let generatedAt: Date
    let nextRunAt: Date
    let hero: HeroDTO
    let actions: [ActionDTO]
    let calendar: [CalEventDTO]
    let stats: BriefingStatsDTO
    let sourcesHealth: [String: String]
}

struct HeroDTO: Codable, Hashable {
    let eyebrow: String
    let title: String
    let focusBadge: String
    let focusBody: String
    let countNumber: Int
    let countLabel: String
}

struct ActionDTO: Codable, Hashable, Identifiable {
    let id: String
    let index: Int
    let priority: Priority
    let title: String
    let source: Source
    let sourceMeta: String
    let context: String
    let deadline: String
    let deadlineHint: String
    let deadlineTone: DeadlineTone
    let done: Bool
    let deepLink: String?

    enum Priority: String, Codable, Hashable { case urgent, important, normal }
    enum Source: String, Codable, Hashable { case email, task, slack, meet }
    enum DeadlineTone: String, Codable, Hashable { case urgent, soon, normal, done }
}

struct CalEventDTO: Codable, Hashable, Identifiable {
    let time: String
    let endTime: String
    let state: State
    let title: String
    let subtitle: String
    let flag: String?

    enum State: String, Codable, Hashable { case done, now, next }

    /// CalEvent has no stable ID from upstream; derive from time + title.
    var id: String { "\(time)|\(title)" }
}

struct BriefingStatsDTO: Codable, Hashable {
    let total: Int
    let urgent: Int
    let important: Int
    let done: Int
}

struct BriefingScheduleDTO: Codable, Hashable {
    let schemaVersion: Int
    let cronExpr: String
    let enabled: Bool
    let timezone: String
    let lastRunAt: String
    let lastRunStatus: String
}

/// Result of `csw briefing schedule check --json` — used by the widget poll.
struct BriefingScheduleCheckDTO: Codable, Hashable {
    let shouldRun: Bool
    let nextRunAt: String
    let lastBriefingDate: String
    let enabled: Bool
}
