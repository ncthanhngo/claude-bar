import Foundation
import WebKit
import AppKit

/// Fetches JSON from `claude.ai` via a hidden WKWebView. Anthropic's
/// `claude.ai/api/*` endpoints sit behind Cloudflare's browser-fingerprint
/// checks; raw URLSession requests get challenged or blocked, so we run them
/// through a real WebKit instance with the user's `sessionKey` cookie injected.
@MainActor
final class WebSessionClient: NSObject {

    static let shared = WebSessionClient()

    enum WebError: LocalizedError {
        case noSession
        case timeout
        case decode(String)
        case http(Int)
        case challenge(String)

        var errorDescription: String? {
            switch self {
            case .noSession:        return "No sessionKey set. Connect to claude.ai first."
            case .timeout:          return "Request timed out."
            case .decode(let m):    return "JSON decode failed: \(m)"
            case .http(let s):      return "HTTP \(s)"
            case .challenge(let s): return "Cloudflare challenge or unexpected page (\(s))."
            }
        }
    }

    private let webView: WKWebView
    private var pending: CheckedContinuation<Void, Never>?

    override init() {
        let cfg = WKWebViewConfiguration()
        // Persistent data store keeps cookies across app launches.
        cfg.websiteDataStore = WKWebsiteDataStore.default()
        // JS on by default — no need to set deprecated `javaScriptEnabled`.
        self.webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        self.webView.navigationDelegate = self
        // Standard macOS Safari UA — keeps Cloudflare's heuristics happy.
        self.webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    // MARK: - Cookie management

    func setSessionKey(_ key: String) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        // Remove any existing sessionKey before setting a new one.
        let cookies = await store.allCookies()
        for c in cookies where c.name == "sessionKey" {
            await store.deleteCookie(c)
        }
        let cookie = HTTPCookie(properties: [
            .domain: ".claude.ai",
            .path: "/",
            .name: "sessionKey",
            .value: key,
            .secure: true,
            .expires: Date().addingTimeInterval(60 * 86400)
        ])!
        await store.setCookie(cookie)
    }

    func clearSession() async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        for c in cookies where c.domain.contains("claude.ai") {
            await store.deleteCookie(c)
        }
    }

    func hasSessionKey() async -> Bool {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        return cookies.contains { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }
    }

    // MARK: - Fetch

    /// Navigate the hidden WebView to `url` and return the JSON payload from
    /// the rendered body.
    func fetchJSON(url: URL, timeout: TimeInterval = 12) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        // Drive navigation to completion via a continuation.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.pending = cont
            self.webView.load(req)
        }

        // Pull the rendered body — the API endpoint serves raw JSON which
        // WebKit wraps in <pre>…</pre> or shows as text.
        let scriptResult = try await runJS("document.body ? document.body.innerText : ''")
        guard let text = scriptResult as? String, !text.isEmpty else {
            throw WebError.challenge("empty body")
        }

        // Heuristic — Cloudflare challenge pages contain "Just a moment".
        if text.contains("Just a moment") || text.contains("Enable JavaScript") {
            throw WebError.challenge("Cloudflare interstitial")
        }

        guard let data = text.data(using: .utf8) else {
            throw WebError.decode("non-utf8 body")
        }
        // Sanity check — must parse as JSON.
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw WebError.decode("not JSON: \(text.prefix(120))")
        }
        return data
    }

    private func runJS(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(script) { result, error in
                if let error { cont.resume(throwing: error) }
                else        { cont.resume(returning: result) }
            }
        }
    }
}

extension WebSessionClient: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.resumePending() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumePending() }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumePending() }
    }

    private func resumePending() {
        guard let cont = pending else { return }
        pending = nil
        cont.resume()
    }
}
