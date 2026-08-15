import Foundation

/// News-specific subprocess calls. Mirrors the (Phase 2) Go side at
/// `backend/cmd/csw/cmd_news.go` and the CLI surface locked in
/// `plans/260815-1455-news-dashboard/contract.md`.
///
/// Phase 1 only DEFINES these — `NewsStore.refresh()` still loads the bundled
/// mock fixture. `NewsSettingsView` calls `newsConfigGet`/`newsConfigSet`
/// directly and is expected to surface a friendly error until Phase 2 lands
/// the backend command (see its `.task` / catch handling).
extension CswClient {
    /// Last persisted `NewsFeed` — fast, no network. Empty feed on first run.
    func newsShow() async throws -> NewsFeed {
        try await run(["news", "show", "--json"], decode: NewsFeed.self)
    }

    /// Aggregate now (feeds + repos + AI) and persist. `force` bypasses any
    /// backend-side cadence/cache check.
    func newsFetch(force: Bool = false) async throws -> NewsFeed {
        var args = ["news", "fetch", "--json"]
        if force { args.append("--force") }
        return try await run(args, decode: NewsFeed.self)
    }

    func newsConfigGet() async throws -> NewsConfigDTO {
        try await run(["news", "config", "get", "--json"], decode: NewsConfigDTO.self)
    }

    /// Persists the full config. Sent on stdin (never argv) per contract.md.
    func newsConfigSet(_ config: NewsConfigDTO) async throws {
        let data = try JSONEncoder().encode(config)
        let raw = String(data: data, encoding: .utf8) ?? "{}"
        try await runWithStdin(["news", "config", "set", "--json"], stdin: raw)
    }

    func newsProviders() async throws -> NewsProvidersDTO {
        try await run(["news", "providers", "--json"], decode: NewsProvidersDTO.self)
    }

    // MARK: - Master/Client relay (Phase 4)

    /// Master: push the local snapshot (+ manifest) to the SSH relay host.
    /// Best-effort at the call site — a publish failure must not fail the
    /// local refresh.
    func newsPublish(host: String, dir: String) async throws {
        _ = try await runRaw(["news", "publish", "--host", host, "--dir", dir])
    }

    /// Client: pull the master's snapshot from the SSH relay, verify it, and
    /// return the decoded feed (the backend also caches it so `newsShow()`
    /// keeps working offline).
    func newsPull(host: String, dir: String) async throws -> NewsFeed {
        try await run(["news", "pull", "--host", host, "--dir", dir, "--json"], decode: NewsFeed.self)
    }
}

/// Payload of `csw news config get|set`. Go owns aggregation settings
/// (provider, model, feeds, GitHub queries) — Swift only edits this via the
/// CLI round-trip; per-machine behaviour (role, relay, refresh interval)
/// stays in `AppSettings` @AppStorage instead (see contract.md's "Config
/// ownership split").
struct NewsConfigDTO: Codable, Equatable {
    var schemaVersion: Int
    var provider: String           // "ollama" | "claude"
    var ollamaModel: String
    var claudeFallbackEnabled: Bool
    var feeds: [NewsConfigFeedDTO]
    var githubQueries: [NewsConfigGitHubQueryDTO]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, provider, ollamaModel, claudeFallbackEnabled, feeds, githubQueries
    }

    init(
        schemaVersion: Int = 1, provider: String, ollamaModel: String,
        claudeFallbackEnabled: Bool, feeds: [NewsConfigFeedDTO], githubQueries: [NewsConfigGitHubQueryDTO]
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.ollamaModel = ollamaModel
        self.claudeFallbackEnabled = claudeFallbackEnabled
        self.feeds = feeds
        self.githubQueries = githubQueries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "ollama"
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? ""
        claudeFallbackEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeFallbackEnabled) ?? false
        feeds = try c.decodeIfPresent([NewsConfigFeedDTO].self, forKey: .feeds) ?? []
        githubQueries = try c.decodeIfPresent([NewsConfigGitHubQueryDTO].self, forKey: .githubQueries) ?? []
    }
}

struct NewsConfigFeedDTO: Codable, Equatable, Identifiable {
    var id: String
    var url: String
    var label: String
    /// "rss" | "aiSummary" — matches Swift `NewsFeedConfig.Mode`.
    var mode: String
    var enabled: Bool
}

struct NewsConfigGitHubQueryDTO: Codable, Equatable {
    var topic: String
    var language: String
}

/// Payload of `csw news providers --json`.
struct NewsProvidersDTO: Decodable, Equatable {
    var providers: [String]
    var ollamaModels: [String]
    var ollamaAvailable: Bool
    var claudeAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case providers, ollamaModels, ollamaAvailable, claudeAvailable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([String].self, forKey: .providers) ?? []
        ollamaModels = try c.decodeIfPresent([String].self, forKey: .ollamaModels) ?? []
        ollamaAvailable = try c.decodeIfPresent(Bool.self, forKey: .ollamaAvailable) ?? false
        claudeAvailable = try c.decodeIfPresent(Bool.self, forKey: .claudeAvailable) ?? false
    }
}
