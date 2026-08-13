import Foundation

/// Mirrors backend/internal/usecase/briefing/signals.go.
///
/// The Workspace feed is the live, rule-derived action surface behind the Daily
/// "Workspace" tab — distinct from the editorial BriefingDTO. Each signal keeps
/// upstream IDs in `meta` so a later approve→execute step can reach the right
/// MCP write tool without re-fetching.
struct WorkspaceFeedDTO: Codable, Hashable {
    let schemaVersion: Int
    let generatedAt: Date
    let signals: [WorkspaceSignalDTO]
    let sourcesHealth: [String: String]
}

struct WorkspaceSignalDTO: Codable, Hashable, Identifiable {
    let id: String
    let kind: Kind
    let source: Source
    let title: String
    let context: String
    let actor: String
    let timestamp: Date
    let urgency: Urgency
    let deepLink: String?
    let meta: [String: String]?

    enum Kind: String, Codable, Hashable {
        case mention, dm, email, taskDue = "task_due"
        case meetingNow = "meeting_now", meetingNext = "meeting_next"
    }
    enum Source: String, Codable, Hashable { case slack, gmail, clickup, gcal }
    enum Urgency: String, Codable, Hashable { case urgent, soon, normal }

    /// Whether an approved draft for this signal can be sent in-app. Email and
    /// meetings have no send surface — those are open-only.
    var isExecutable: Bool {
        switch kind { case .mention, .dm, .taskDue: return true; default: return false }
    }
}

/// AI-drafted action body for one signal (`csw workspace draft`).
struct WorkspaceDraftDTO: Codable, Hashable {
    let draft: String
    let rationale: String?
}

/// Outcome of executing an approved action (`csw workspace execute`).
struct WorkspaceExecuteResultDTO: Codable, Hashable {
    let ok: Bool
    let detail: String?
}
