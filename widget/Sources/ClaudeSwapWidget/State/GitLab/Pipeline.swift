import Foundation

/// A single GitLab CI/CD pipeline run, decoded from `csw gitlab pipelines`
/// (which passes the GitLab REST JSON through verbatim). Dates are parsed by
/// `CswClient`'s shared decoder, which already tolerates GitLab's
/// fractional-second ISO8601 timestamps.
struct Pipeline: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let projectId: Int?
    let iid: Int?
    let ref: String?
    let sha: String?
    let status: PipelineStatus
    let source: String?
    let webUrl: String?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, iid, ref, sha, status, source
        case projectId = "project_id"
        case webUrl = "web_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Short 8-char SHA for compact display.
    var shortSHA: String { sha.map { String($0.prefix(8)) } ?? "" }
}
