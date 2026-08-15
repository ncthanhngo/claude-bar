import Foundation

/// Render model for the News dashboard. Field names mirror
/// `plans/260815-1455-news-dashboard/contract.md` `NewsFeed` EXACTLY — the Go
/// backend (`csw news show|fetch`) is the schema authority and
/// `NewsStore.refresh()` decodes its output at runtime. `Resources/news-mock.json`
/// is a decode-robustness test fixture only (see `NewsDTOTests`), not a runtime
/// data source.
///
/// Timestamps stay raw RFC3339 strings rather than `Date` so a malformed or
/// empty value (contract explicitly allows `publishedAt`/`generatedAt` to be
/// empty) never fails the whole decode — callers that want a `Date` use
/// `NewsDateFormatting.parse(_:)`.
struct NewsFeed: Decodable, Equatable {
    var schemaVersion: Int
    var generatedAt: String
    /// "master" | "client" — the role that produced this snapshot.
    var role: String
    /// "ollama" | "claude" — the provider actually used.
    var provider: String
    var model: String
    var items: [NewsCard]
    var repos: [RepoCard]
    var sourcesHealth: [String: String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, role, provider, model, items, repos, sourcesHealth
    }

    init(
        schemaVersion: Int,
        generatedAt: String,
        role: String,
        provider: String,
        model: String,
        items: [NewsCard],
        repos: [RepoCard],
        sourcesHealth: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.role = role
        self.provider = provider
        self.model = model
        self.items = items
        self.repos = repos
        self.sourcesHealth = sourcesHealth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "master"
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "ollama"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        // Defensive default: a Go `nil` slice serializes to JSON `null`,
        // which fails a plain `[T]` decode. Falling back to `[]` here means
        // a backend regression degrades to an empty section instead of
        // nuking the whole feed — see contract.md's nil-slice note and the
        // "Go nil slice breaks Swift decode" incident this mirrors.
        items = try c.decodeIfPresent([NewsCard].self, forKey: .items) ?? []
        repos = try c.decodeIfPresent([RepoCard].self, forKey: .repos) ?? []
        sourcesHealth = try c.decodeIfPresent([String: String].self, forKey: .sourcesHealth) ?? [:]
    }

    static let empty = NewsFeed(
        schemaVersion: 1, generatedAt: "", role: "master", provider: "ollama",
        model: "", items: [], repos: [], sourcesHealth: [:]
    )
}

/// `category` ∈ ai | dev | github | iot | other (contract.md). Unknown
/// strings (a future backend addition ahead of an app update) fall back to
/// `.other` instead of failing the decode. `Encodable` (default synthesis —
/// round-trips as its raw string) is needed so `NewsCard`/`RepoCard` can be
/// re-encoded as the `csw news save` stdin payload (see `NewsStore.toggleSaveItem`).
enum NewsCategory: String, Codable, CaseIterable, Equatable, Identifiable {
    case ai, dev, github, iot, other

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NewsCategory(rawValue: raw) ?? .other
    }

    /// Vietnamese tab label, matching the Aurora Glass mockup's `.tabs`.
    var label: String {
        switch self {
        case .ai:     return "AI & LLM"
        case .dev:    return "Dev tools"
        case .github: return "GitHub"
        case .iot:    return "IoT"
        case .other:  return "Khác"
        }
    }

    /// CSS badge class in the mockup (`.b-v/.b-c/.b-r/.b-a/.b-g`) mapped to
    /// a SwiftUI color for the image-card category chip.
    var badgeColor: (r: Double, g: Double, b: Double) {
        switch self {
        case .ai:     return (124.0 / 255, 92.0 / 255, 255.0 / 255)   // violet
        case .dev:    return (14.0 / 255, 165.0 / 255, 190.0 / 255)   // cyan
        case .github: return (5.0 / 255, 150.0 / 255, 105.0 / 255)    // green
        case .iot:    return (217.0 / 255, 119.0 / 255, 6.0 / 255)    // amber
        case .other:  return (244.0 / 255, 63.0 / 255, 94.0 / 255)    // rose
        }
    }
}

/// One news item — a glass card with an image, source favicon, VN summary,
/// and (on hover) the full VN translation. `Encodable` (default synthesis
/// from `CodingKeys`, which already matches contract.md field-for-field) so
/// `NewsStore` can re-encode a card as the `csw news save --kind item` stdin
/// payload.
struct NewsCard: Codable, Identifiable, Equatable {
    let id: String
    let category: NewsCategory
    let title: String
    let titleVI: String
    let sourceLabel: String
    let sourceFaviconURL: String
    let imageURL: String
    let summaryVI: String
    let fullVI: String
    let originalURL: String
    /// Raw RFC3339 string; empty when unknown. Parse with
    /// `NewsDateFormatting.parse(_:)` for display.
    let publishedAt: String

    enum CodingKeys: String, CodingKey {
        case id, category, title, titleVI, sourceLabel, sourceFaviconURL,
             imageURL, summaryVI, fullVI, originalURL, publishedAt
    }

    init(
        id: String, category: NewsCategory, title: String, titleVI: String,
        sourceLabel: String, sourceFaviconURL: String, imageURL: String,
        summaryVI: String, fullVI: String, originalURL: String, publishedAt: String
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.titleVI = titleVI
        self.sourceLabel = sourceLabel
        self.sourceFaviconURL = sourceFaviconURL
        self.imageURL = imageURL
        self.summaryVI = summaryVI
        self.fullVI = fullVI
        self.originalURL = originalURL
        self.publishedAt = publishedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Defensive like every other field here (and RepoCard.id): a single
        // id-less item degrades to a synthetic id instead of failing the whole
        // NewsFeed decode.
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        category = try c.decodeIfPresent(NewsCategory.self, forKey: .category) ?? .other
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        titleVI = try c.decodeIfPresent(String.self, forKey: .titleVI) ?? ""
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        sourceFaviconURL = try c.decodeIfPresent(String.self, forKey: .sourceFaviconURL) ?? ""
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL) ?? ""
        summaryVI = try c.decodeIfPresent(String.self, forKey: .summaryVI) ?? ""
        fullVI = try c.decodeIfPresent(String.self, forKey: .fullVI) ?? ""
        originalURL = try c.decodeIfPresent(String.self, forKey: .originalURL) ?? ""
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt) ?? ""
    }
}

/// One GitHub repo card. `Encodable` for the same reason as `NewsCard` —
/// `csw news save --kind repo` takes the card JSON on stdin.
struct RepoCard: Codable, Identifiable, Equatable {
    let id: String
    let fullName: String
    let descVI: String
    let language: String
    /// Hex string e.g. "#00add8" — GitHub's per-language color.
    let langColor: String
    let stars: Int
    let deltaWeek: Int
    let url: String
    let category: NewsCategory

    enum CodingKeys: String, CodingKey {
        case id, fullName, descVI, language, langColor, stars, deltaWeek, url, category
    }

    init(
        id: String, fullName: String, descVI: String, language: String,
        langColor: String, stars: Int, deltaWeek: Int, url: String, category: NewsCategory
    ) {
        self.id = id
        self.fullName = fullName
        self.descVI = descVI
        self.language = language
        self.langColor = langColor
        self.stars = stars
        self.deltaWeek = deltaWeek
        self.url = url
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? ""
        descVI = try c.decodeIfPresent(String.self, forKey: .descVI) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        langColor = try c.decodeIfPresent(String.self, forKey: .langColor) ?? "#8899aa"
        stars = try c.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        deltaWeek = try c.decodeIfPresent(Int.self, forKey: .deltaWeek) ?? 0
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        category = try c.decodeIfPresent(NewsCategory.self, forKey: .category) ?? .github
    }
}

/// Shared RFC3339 parsing for the raw timestamp strings above. Two format
/// variants because the Go backend may or may not emit fractional seconds.
enum NewsDateFormatting {
    private static let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func parse(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        if let d = try? withFractional.parse(raw) { return d }
        if let d = try? plain.parse(raw) { return d }
        return nil
    }

    /// Compact Vietnamese relative label ("2 giờ", "hôm qua") matching the
    /// mockup's `.src .t` pill. Falls back to an empty string when the raw
    /// timestamp is missing/unparseable so the source row simply omits it.
    static func relativeLabel(_ raw: String) -> String {
        guard let date = parse(raw) else { return "" }
        let seconds = -date.timeIntervalSinceNow
        guard seconds > 0 else { return "vừa xong" }
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if minutes < 60 { return "\(max(1, Int(minutes))) phút" }
        if hours < 24 { return "\(Int(hours)) giờ" }
        if days < 2 { return "hôm qua" }
        return "\(Int(days)) ngày"
    }
}
