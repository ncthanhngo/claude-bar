import Foundation

/// One news source the briefing should pull into the "Tin đáng đọc" mini card.
///
/// Persisted as a JSON-encoded array under
/// `AppSettings.briefingNewsFeedsJSON`. Backend fetcher is deferred — this
/// type only locks the schema.
struct NewsFeedConfig: Codable, Hashable, Identifiable {
    enum Mode: String, Codable, Hashable, CaseIterable, Identifiable {
        /// Pull RSS / Atom feed at the URL directly.
        case rss
        /// Hand the URL to Claude with a "summarize this page" prompt.
        case aiSummary

        var id: String { rawValue }
        var label: String {
            switch self {
            case .rss:       return "RSS / Atom"
            case .aiSummary: return "AI tóm tắt từ trang"
            }
        }
    }

    let id: UUID
    var url: String
    var label: String      // human-readable name e.g. "Hacker News"
    var mode: Mode
    var enabled: Bool

    init(id: UUID = UUID(), url: String, label: String, mode: Mode = .rss, enabled: Bool = true) {
        self.id = id
        self.url = url
        self.label = label
        self.mode = mode
        self.enabled = enabled
    }
}

extension Array where Element == NewsFeedConfig {
    /// Decode the AppStorage JSON. Returns empty on malformed/empty input.
    static func decode(from json: String) -> [NewsFeedConfig] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([NewsFeedConfig].self, from: data)) ?? []
    }

    /// Encode back to a JSON string for AppStorage.
    func encodeToJSON() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
