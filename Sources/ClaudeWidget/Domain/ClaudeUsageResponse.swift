import Foundation

/// Response from `https://claude.ai/api/organizations/<orgId>/usage`.
/// Mirrors the fields used by claude-usage-widget (Slavomir Durej).
struct ClaudeUsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct Window: Decodable {
        /// Percent (0-100) of the window consumed.
        let utilization: Double
        /// ISO-8601 timestamp when the window resets.
        let resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.utilization = try c.decode(Double.self, forKey: .utilization)
            if let raw = try c.decodeIfPresent(String.self, forKey: .resetsAt) {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                self.resetsAt = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
            } else {
                self.resetsAt = nil
            }
        }
    }
}

/// Response from `https://claude.ai/api/organizations`. Returns an array of orgs;
/// we use the first org's UUID.
struct ClaudeOrgListEntry: Decodable {
    let uuid: String
    let name: String?
}
