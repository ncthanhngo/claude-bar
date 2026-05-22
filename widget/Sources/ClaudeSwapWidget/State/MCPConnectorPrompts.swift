import Foundation

/// Per-connector markdown instructions the briefing runner passes to
/// Claude. One block per service so the model gets focused guidance for
/// every MCP source it queries — e.g. user can say "Slack: only #engineering
/// and DMs; ignore announcement channels" without bloating the global
/// briefing user prompt.
///
/// Google account exposes three logically-distinct MCP surfaces (Drive,
/// Gmail, Calendar) under one OAuth credential — we surface them as
/// independent tags so the user can write different focus per surface.
struct MCPConnectorPrompts: Codable, Hashable {
    var slack: String = ""
    var clickup: String = ""
    var gdrive: String = ""
    var gmail: String = ""
    var gcal: String = ""
    var gsheets: String = ""

    /// Returns the entry for a given tag key — handy for the UI binding to
    /// each TextEditor without writing six properties manually.
    func value(for tag: Tag) -> String {
        switch tag {
        case .slack:   return slack
        case .clickup: return clickup
        case .gdrive:  return gdrive
        case .gmail:   return gmail
        case .gcal:    return gcal
        case .gsheets: return gsheets
        }
    }

    mutating func set(_ tag: Tag, to value: String) {
        switch tag {
        case .slack:   slack = value
        case .clickup: clickup = value
        case .gdrive:  gdrive = value
        case .gmail:   gmail = value
        case .gcal:    gcal = value
        case .gsheets: gsheets = value
        }
    }

    enum Tag: String, CaseIterable, Codable, Identifiable {
        case slack, clickup, gdrive, gmail, gcal, gsheets
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .slack:   return "Slack"
            case .clickup: return "ClickUp"
            case .gdrive:  return "Google Drive"
            case .gmail:   return "Gmail"
            case .gcal:    return "Google Calendar"
            case .gsheets: return "Google Sheets"
            }
        }

        /// SF Symbol for the small chip icon.
        var symbolName: String {
            switch self {
            case .slack:   return "number"
            case .clickup: return "list.bullet.rectangle"
            case .gdrive:  return "doc.fill"
            case .gmail:   return "envelope.fill"
            case .gcal:    return "calendar"
            case .gsheets: return "tablecells"
            }
        }

        /// True when the tag is a sub-surface of the gdrive OAuth scope —
        /// rendered inside the Google connector disclosure rather than as
        /// its own connector row.
        var isGoogleSubTag: Bool {
            self == .gdrive || self == .gmail || self == .gcal || self == .gsheets
        }
    }

    static let empty = MCPConnectorPrompts()
}

extension MCPConnectorPrompts {
    /// Decode the AppStorage JSON. Returns the empty default on malformed
    /// or absent input — never throws.
    static func decode(from json: String) -> MCPConnectorPrompts {
        guard let data = json.data(using: .utf8),
              let v = try? JSONDecoder().decode(MCPConnectorPrompts.self, from: data) else {
            return .empty
        }
        return v
    }

    func encodeToJSON() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
