import Foundation
import Combine

/// Pulls enabled RSS / Atom feeds from `AppSettings.briefingNewsFeedsJSON`,
/// parses headlines via XMLParser, and exposes the merged result so the
/// PLAN reading card can render. Refreshes on bind (and on demand via
/// `refresh()`). Background fetches off the main actor.
@MainActor
final class NewsFeedCoordinator: ObservableObject {
    @Published private(set) var items: [NewsItemDTO] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastUpdated: Date?
    /// True when there's at least one enabled RSS feed configured — even if
    /// fetching returned no items. Lets the empty state distinguish "user
    /// hasn't added a feed yet" from "feed URL is wrong / returned HTML".
    @Published private(set) var hasConfiguredFeeds: Bool = false

    private let settings = AppSettings.shared
    private var refreshTask: Task<Void, Never>?

    /// Limit per feed when merging — keeps the card from drowning in any
    /// single chatty source. Total card max ≈ feeds × 6 items.
    private let perFeedLimit = 6

    /// Kick off the first fetch immediately + schedule periodic refresh.
    func start() {
        refresh()
    }

    /// Force a refetch. Cancellable — calling again cancels the prior run.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.runRefresh()
        }
    }

    private func runRefresh() async {
        let feeds = [NewsFeedConfig].decode(from: settings.briefingNewsFeedsJSON)
            .filter { $0.enabled && $0.mode == .rss && !$0.url.isEmpty }
        self.hasConfiguredFeeds = !feeds.isEmpty
        guard !feeds.isEmpty else {
            self.items = []
            self.lastError = nil
            return
        }
        isLoading = true
        defer { isLoading = false }

        var aggregated: [NewsItemDTO] = []
        var firstError: String?
        var zeroItemFeeds: [String] = []
        for feed in feeds {
            if Task.isCancelled { return }
            do {
                let parsed = try await fetchAndParse(feed: feed)
                if parsed.isEmpty {
                    zeroItemFeeds.append(feed.label)
                } else {
                    aggregated.append(contentsOf: parsed.prefix(perFeedLimit))
                }
            } catch {
                if firstError == nil {
                    firstError = "\(feed.label): \(error.localizedDescription)"
                }
            }
        }
        aggregated.sort { (a, b) in
            (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
        }
        self.items = aggregated
        self.lastUpdated = Date()
        // Synthesize a helpful error when fetch succeeded but the URL is not
        // an actual RSS / Atom document — common when users paste a tag /
        // listing page instead of the feed permalink.
        if firstError == nil && !zeroItemFeeds.isEmpty && aggregated.isEmpty {
            let labels = zeroItemFeeds.joined(separator: ", ")
            firstError = "\(labels): không phải feed RSS hợp lệ (URL có thể là trang HTML, không phải feed). Ví dụ TechCrunch: dùng https://techcrunch.com/feed/"
        }
        self.lastError = firstError
    }

    private nonisolated func fetchAndParse(feed: NewsFeedConfig) async throws -> [NewsItemDTO] {
        guard let url = URL(string: feed.url) else {
            throw NSError(domain: "NewsFeed", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "URL không hợp lệ"])
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("ClaudeBar/0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8",
                     forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "NewsFeed", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let parser = RSSAtomParser(feedID: feed.id, feedLabel: feed.label)
        return parser.parse(data: data)
    }
}

/// Lightweight XMLParser-driven RSS 2.0 + Atom 1.0 reader. We only extract
/// title + link + pubDate per item — enough for the reading card. Anything
/// the parser can't recognise is silently skipped so a malformed feed
/// doesn't break the rest of the aggregation.
final class RSSAtomParser: NSObject, XMLParserDelegate {
    private let feedID: UUID
    private let feedLabel: String

    private var current: PartialItem?
    private var captureBuffer: String = ""
    private var captureMode: Capture = .none
    private var atomLinkHref: String?

    private var items: [NewsItemDTO] = []

    private enum Capture { case none, title, link, pubDate, summary }

    init(feedID: UUID, feedLabel: String) {
        self.feedID = feedID
        self.feedLabel = feedLabel
    }

    func parse(data: Data) -> [NewsItemDTO] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return items
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let tag = elementName.lowercased()
        switch tag {
        case "item", "entry":
            current = PartialItem()
            atomLinkHref = nil
        case "title":
            captureMode = .title
            captureBuffer = ""
        case "link":
            // Atom uses <link href="..."/> with no body; RSS uses <link>url</link>.
            if let href = attributeDict["href"], !href.isEmpty {
                atomLinkHref = href
                captureMode = .none
            } else {
                captureMode = .link
                captureBuffer = ""
            }
        case "pubdate", "published", "updated":
            captureMode = .pubDate
            captureBuffer = ""
        case "description", "summary", "content", "content:encoded":
            // Only grab the first summary-like field per item — feeds that
            // emit both <description> and <content:encoded> would otherwise
            // overwrite each other (the second usually being the longer
            // HTML body which we'd rather not show as a tooltip).
            if current?.summary == nil {
                captureMode = .summary
                captureBuffer = ""
            } else {
                captureMode = .none
            }
        default:
            captureMode = .none
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureMode != .none {
            captureBuffer += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if captureMode != .none,
           let s = String(data: CDATABlock, encoding: .utf8) {
            captureBuffer += s
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let tag = elementName.lowercased()
        switch tag {
        case "title":
            current?.title = captureBuffer.trimmed()
        case "link":
            if let href = atomLinkHref, current?.link == nil {
                current?.link = href
            } else if !captureBuffer.isEmpty {
                current?.link = captureBuffer.trimmed()
            }
        case "pubdate", "published", "updated":
            current?.publishedAt = Self.parseDate(captureBuffer.trimmed())
        case "description", "summary", "content", "content:encoded":
            if current?.summary == nil {
                current?.summary = Self.cleanSummary(captureBuffer)
            }
        case "item", "entry":
            if let item = current?.build(feedID: feedID, feedLabel: feedLabel) {
                items.append(item)
            }
            current = nil
        default:
            break
        }
        captureMode = .none
    }

    /// Strip HTML tags, collapse whitespace, decode the common entities, and
    /// truncate to a tooltip-friendly length. `nil` for empty input.
    static func cleanSummary(_ raw: String) -> String? {
        var s = raw
        // Drop any tag with `<…>` — RSS descriptions are almost always HTML.
        s = s.replacingOccurrences(of: "<[^>]+>",
                                    with: " ",
                                    options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"),
            ("&quot;", "\""), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"),
            ("&hellip;", "…"),
            ("&#8217;", "'"), ("&#8216;", "'"),
            ("&#8220;", "\u{201C}"), ("&#8221;", "\u{201D}"),
            ("&#8211;", "–"), ("&#8212;", "—"),
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = s.replacingOccurrences(of: "\\s+",
                                    with: " ",
                                    options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let cap = 400
        if s.count <= cap { return s }
        let idx = s.index(s.startIndex, offsetBy: cap)
        return s[..<idx].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // MARK: - Helpers

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",       // RFC 822 (RSS)
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",        // Atom
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()

    static func parseDate(_ s: String) -> Date? {
        for f in dateFormatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

private struct PartialItem {
    var title: String?
    var link: String?
    var publishedAt: Date?
    var summary: String?

    func build(feedID: UUID, feedLabel: String) -> NewsItemDTO? {
        guard let title, !title.isEmpty, let link, !link.isEmpty else { return nil }
        return NewsItemDTO(
            feedID: feedID,
            feedLabel: feedLabel,
            title: title,
            link: link,
            publishedAt: publishedAt,
            summary: summary
        )
    }
}

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
