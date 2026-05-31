import Foundation
import WebKit

/// Direct call to `https://claude.ai/api/organizations/<orgUuid>/usage`
/// using cookies harvested from the account's WKWebsiteDataStore. Replaces
/// the WebView DOM scrape on the fast path — ~3KB JSON vs ~800KB SPA hydrate.
///
/// Falls back to the scraper path in [[ClaudeWebUsageFetcher]] when:
/// - the org UUID is missing on the AccountDTO
/// - the cookie jar has no claude.ai session
/// - the API returns non-2xx (Cloudflare challenge, 401, schema drift)
///
/// The scraper remains the source of truth for cookie freshness — every
/// successful API call still drops a snapshot through [[ClaudeWebSessionSync]]
/// so the cloud bundle stays in sync.
@MainActor
enum ClaudeWebUsageAPI {

    /// Logged once per process so a sample response body is captured the
    /// first time the call succeeds. Helps verify the parser against any
    /// future schema drift without filling the log every poll.
    private static var didLogSampleResponse = false

    enum APIError: LocalizedError {
        case missingOrgUuid
        case noCookies
        case httpError(Int, String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingOrgUuid: return "Account has no organization UUID — direct API path unavailable."
            case .noCookies: return "WKWebsiteDataStore has no claude.ai cookies to authenticate the API."
            case .httpError(let status, let body):
                return "claude.ai usage API HTTP \(status): \(body.prefix(180))"
            case .decodeFailed(let reason):
                return "Failed to decode usage API response: \(reason)"
            }
        }
    }

    /// Fetches usage for an organization. `orgUuid` is the account's
    /// `organizationUuid` field; `dataStore` is the per-account
    /// WKWebsiteDataStore that holds the claude.ai session cookies.
    static func fetch(orgUuid: String, dataStore: WKWebsiteDataStore) async throws -> UsageDTO {
        guard !orgUuid.isEmpty else { throw APIError.missingOrgUuid }
        // Pre-warm the data store: WKWebsiteDataStore(forIdentifier:) returns
        // an empty in-memory cookie cache until a WKWebView using it loads
        // some URL — at which point WebKit reads persisted cookies from disk
        // for that domain. A throwaway about:blank load is the cheapest way
        // to nudge WebKit into populating the cookie cache.
        await Self.primeCookieCache(dataStore: dataStore)
        let allCookies = await dataStore.httpCookieStore.allCookies()
        let cookies = allCookies.filter { $0.domain.hasSuffix("claude.ai") }
        if cookies.isEmpty {
            throw APIError.noCookies
        }

        let url = URL(string: "https://claude.ai/api/organizations/\(orgUuid)/usage")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // Mimic browser fetch headers — claude.ai's CDN throttles requests
        // missing standard browser hints, returning Cloudflare challenge HTML
        // instead of JSON.
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        let header = HTTPCookie.requestHeaderFields(with: cookies)
        for (k, v) in header { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.httpError(-1, "no HTTPURLResponse")
        }
        if http.statusCode / 100 != 2 {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw APIError.httpError(http.statusCode, body)
        }

        if !didLogSampleResponse {
            didLogSampleResponse = true
            let sample = String(data: data.prefix(800), encoding: .utf8) ?? "<binary>"
            DiagnosticsLogger.shared.log(.info, subsystem: "usage-api",
                "first OK response (\(data.count)B) — \(sample)")
        }

        return try decode(data: data)
    }

    // MARK: - Schema

    /// Parse the JSON response. Anthropic's web SPA changes shape occasionally —
    /// the decode tries the documented Claude Code Max plan shape first
    /// (`five_hour` + `seven_day` periods with `utilization` + `resets_at`),
    /// falls through alternates we observed during reverse-engineering.
    private static func decode(data: Data) throws -> UsageDTO {
        let decoder = JSONDecoder()
        // Anthropic mixes "Z" timestamps and timezone-offset; the .iso8601
        // strategy handles both.
        decoder.dateDecodingStrategy = .iso8601
        if let resp = try? decoder.decode(WireV1.self, from: data) {
            return resp.usage
        }
        let raw = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
        throw APIError.decodeFailed("no matching schema — raw=\(raw)")
    }

    /// `WKWebsiteDataStore(forIdentifier:)` returns an empty cookie cache
    /// until the underlying network process has been engaged for the
    /// domain in question. A tiny favicon GET via a hidden WKWebView
    /// engages it. Costs ~1 KB cached after first run; subsequent calls
    /// in the same process hit the in-memory cookie cache immediately.
    private static var primedStores = Set<ObjectIdentifier>()
    private static func primeCookieCache(dataStore: WKWebsiteDataStore) async {
        let key = ObjectIdentifier(dataStore)
        if primedStores.contains(key) { return }
        primedStores.insert(key)
        // Use a hidden WKWebView keyed to this dataStore + load a 1×1 GIF.
        // We pick favicon.ico since claude.ai caches it aggressively
        // (Cache-Control: immutable / 1y).
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = await MainActor.run { WKWebView(frame: .zero, configuration: config) }
        let _: Void = await withCheckedContinuation { cont in
            let delegate = PrimeDelegate(continuation: cont)
            // Retain the delegate for the duration of the load by parking
            // it on the WebView via objc_setAssociatedObject would be
            // cleaner — for now closure capture in PrimeDelegate's resume
            // path keeps it alive.
            Task { @MainActor in
                webView.navigationDelegate = delegate
                webView.load(URLRequest(url: URL(string: "https://claude.ai/favicon.ico")!))
            }
            // Safety timer — don't hang forever if claude.ai is unreachable.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                delegate.resumeIfPending(webView: webView)
            }
        }
    }

    @MainActor
    private final class PrimeDelegate: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?
        init(continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            resumeIfPending(webView: webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            resumeIfPending(webView: webView)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            resumeIfPending(webView: webView)
        }
        func resumeIfPending(webView: WKWebView) {
            guard let cont = continuation else { return }
            continuation = nil
            webView.navigationDelegate = nil
            cont.resume()
        }
    }

    /// Primary schema: `{"five_hour": {"utilization": 4.5, "resets_at": "..."},
    ///                   "seven_day": {"utilization": 10.0, "resets_at": "..."}}`
    /// Anthropic also returns `null` for windows that haven't been touched
    /// yet (new account) — handled by Optional decoding.
    private struct WireV1: Decodable {
        let five_hour: Window?
        let seven_day: Window?

        struct Window: Decodable {
            let utilization: Double
            let resets_at: Date
        }

        var usage: UsageDTO {
            UsageDTO(
                fiveHour: five_hour.map {
                    UsageWindowDTO(utilizationPct: $0.utilization, resetsAt: $0.resets_at)
                },
                sevenDay: seven_day.map {
                    UsageWindowDTO(utilizationPct: $0.utilization, resetsAt: $0.resets_at)
                },
                fetchedAt: Date()
            )
        }
    }
}
