import SwiftUI
import WebKit

enum ClaudeWebUsageError: LocalizedError {
    case usagePageNotReady
    case usageUnavailable

    var errorDescription: String? {
        switch self {
        case .usagePageNotReady:
            return "Claude web usage page did not finish loading."
        case .usageUnavailable:
            return "Claude web usage did not expose a 5h or 7d quota window."
        }
    }
}

/// NSViewRepresentable wrapper around WKWebView, the same engine Safari uses.
///
/// Configured with the account profile's WKWebsiteDataStore so cookies and
/// localStorage persist across widget launches for web usage refreshes.
struct ClaudeWebView: NSViewRepresentable {
    let initialURL: URL
    let dataStore: WKWebsiteDataStore
    @Binding var currentURL: URL?
    @Binding var isLoading: Bool
    @Binding var title: String
    let onCookiesChanged: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: initialURL))
        return view
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: ClaudeWebView
        init(parent: ClaudeWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            parent.isLoading = false
            parent.currentURL = webView.url
            parent.title = webView.title ?? ""
            parent.onCookiesChanged()
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            parent.isLoading = false
        }
    }
}

/// Loads claude.ai's usage page in a hidden WKWebView and returns the same
/// windows the widget renders for terminal usage.
@MainActor
final class ClaudeWebUsageFetcher: NSObject, WKNavigationDelegate {
    private let usageURL = URL(string: "https://claude.ai/settings/usage")!
    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    init(dataStore: WKWebsiteDataStore) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func fetchUsage() async throws -> UsageDTO {
        try await reloadUsagePage()
        // claude.ai is a React SPA — `didFinish` fires when HTML+JS is loaded
        // but the usage numbers arrive via a follow-up XHR. The weekly-limit
        // block hydrates several seconds AFTER the 5h block in steady state,
        // so returning the first payload that has either window typically
        // captures 5h with `sevenDay: nil`. Per-account merging upstream
        // recovers the previous 7d, but only until that window's resetsAt
        // expires — then the 7d bar flickers on/off until the SPA finally
        // re-renders it. Wait for BOTH windows (up to ~8s) before returning;
        // if only 5h hydrated after the cap, accept the partial result so
        // accounts where claude.ai genuinely doesn't surface 7d (free tier
        // edge cases, scraper miss) still get something.
        let decoder = JSONDecoder()
        var lastError: Error = ClaudeWebUsageError.usageUnavailable
        var lastPayload: WebUsagePayload?
        let maxAttempts = 16            // 16 * 0.5s = 8s ceiling
        let bailIfEmptyAfter = 4        // give up early if SPA never paints
        for attempt in 0..<maxAttempts {
            let result = try await webView.evaluateJavaScript(Self.scrapeScript)
            if let raw = result as? String,
               let data = raw.data(using: .utf8) {
                do {
                    let payload = try decoder.decode(WebUsagePayload.self, from: data)
                    if payload.fiveHour != nil || payload.sevenDay != nil {
                        lastPayload = payload
                    }
                    // Both windows present — done, no need to wait further.
                    if payload.fiveHour != nil && payload.sevenDay != nil {
                        return payload.usage
                    }
                    lastError = ClaudeWebUsageError.usageUnavailable
                } catch {
                    lastError = error
                }
            }
            // Still nothing after ~2s? The SPA either never loaded usage at
            // all (signed-out / wrong session) or is too slow to chase. Let
            // upstream fall back to OAuth instead of burning 8s every poll.
            if attempt >= bailIfEmptyAfter - 1 && lastPayload == nil {
                throw lastError
            }
            if attempt < maxAttempts - 1 {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
        }
        // Hit the 8s ceiling without ever seeing both windows. Return the
        // best partial we collected so 5h doesn't go missing too.
        if let last = lastPayload {
            return last.usage
        }
        throw lastError
    }

    private func reloadUsagePage() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            // Bypass HTTP cache so a recent reset isn't masked by a 304 that
            // re-renders the pre-reset DOM. The default protocol policy lets
            // WKWebView serve `claude.ai/settings/usage` from disk cache,
            // which encodes the old <time datetime> and locks the widget on
            // a `resetsAt` in the past.
            var request = URLRequest(url: usageURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            webView.load(request)
        }
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        finishLoad()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        finishLoad(error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        finishLoad(error)
    }

    private func finishLoad(_ error: Error? = nil) {
        guard let loadContinuation else { return }
        self.loadContinuation = nil
        if let error {
            loadContinuation.resume(throwing: error)
        } else if webView.url == nil {
            loadContinuation.resume(throwing: ClaudeWebUsageError.usagePageNotReady)
        } else {
            loadContinuation.resume()
        }
    }

    private struct WebUsagePayload: Decodable {
        let fiveHour: WebUsageWindow?
        let sevenDay: WebUsageWindow?
        let fetchedAtMillis: Double

        var usage: UsageDTO {
            UsageDTO(
                fiveHour: fiveHour?.window,
                sevenDay: sevenDay?.window,
                fetchedAt: Date(timeIntervalSince1970: fetchedAtMillis / 1000)
            )
        }
    }

    private struct WebUsageWindow: Decodable {
        let utilizationPct: Double
        let resetsAtMillis: Double

        var window: UsageWindowDTO {
            UsageWindowDTO(
                utilizationPct: utilizationPct,
                resetsAt: Date(timeIntervalSince1970: resetsAtMillis / 1000)
            )
        }
    }

    // Anchored on each progressbar (not a parent container that may wrap
    // multiple windows). Two failure modes the previous container-first
    // walk caused:
    //   1. The weekly section now ships per-model bars ("Weekly · Opus")
    //      alongside the all-models bar — a label regex of /weekly/i matched
    //      whichever per-model wrapper sorted shortest first, so accounts
    //      with Opus pinned at 100 % rendered 7d as 100 % even when the
    //      all-models limit had headroom (issue #6, Tk Dev 3).
    //   2. When 5h + 7d both lived inside one compact wrapper, the first
    //      `[role=progressbar]` lookup returned the same node for both
    //      windows, so the two bars rendered identical numbers (issue #6,
    //      Tk Dev 1).
    // Walk up from each progressbar, classify its own smallest labelling
    // ancestor, and explicitly drop per-model weekly blocks.
    private static let scrapeScript = """
    (() => {
      const visibleText = (node) => (node?.innerText || node?.textContent || "").trim();

      function findResetMillis(root) {
        const time = root.querySelector("time[datetime]");
        if (time) {
          const exact = Date.parse(time.getAttribute("datetime"));
          if (Number.isFinite(exact)) return exact;
        }
        const lines = visibleText(root)
          .split(/\\n+/)
          .map((line) => line.trim())
          .filter(Boolean);
        const line = lines.find((candidate) => /resets?/i.test(candidate));
        if (!line) return null;
        const phrase = line.replace(/^.*?resets?\\s+(?:in\\s+)?/i, "").trim();
        const relative = phrase.match(/(?:(\\d+)\\s*d(?:ays?)?)?\\s*(?:(\\d+)\\s*h(?:ours?)?)?\\s*(?:(\\d+)\\s*m(?:in(?:utes?)?)?)?/i);
        if (relative && relative[0].trim()) {
          const days = Number(relative[1] || 0);
          const hours = Number(relative[2] || 0);
          const minutes = Number(relative[3] || 0);
          if (days || hours || minutes) {
            return Date.now() + (((days * 24 + hours) * 60 + minutes) * 60 * 1000);
          }
        }
        const exact = Date.parse(phrase);
        return Number.isFinite(exact) ? exact : null;
      }

      // Walk up from a progressbar to the nearest ancestor whose visible
      // text reads as one self-contained label cell (has a window label and
      // a reset clause but isn't the whole page). Returns { node, text }.
      function labellingAncestor(progress) {
        let node = progress.parentElement;
        let best = null;
        for (let depth = 0; depth < 8 && node; depth++, node = node.parentElement) {
          const text = visibleText(node);
          if (!text || text.length > 900) break;
          const hasLabel = /current\\s+session|5\\s*-?\\s*hour|weekly|all\\s+models|7\\s*-?\\s*day/i.test(text);
          const hasReset = /reset/i.test(text);
          if (hasLabel && hasReset) {
            best = { node, text };
            break;
          }
          if (hasLabel) best = { node, text };
        }
        return best;
      }

      // Classify a label cell as the 5h ("current session") window, the
      // all-models 7d window, or neither. Per-model weekly bars are dropped
      // — they routinely pin at 100 % even when the headline weekly limit
      // has room and are not what the widget displays.
      function classify(text) {
        const t = text.toLowerCase();
        const isWeekly  = /weekly|7\\s*-?\\s*day/.test(t);
        const isSession = /current\\s+session|5\\s*-?\\s*hour/.test(t);
        const hasModelQualifier = /\\b(opus|sonnet|haiku)\\b/.test(t);
        if (isSession && !isWeekly) return "fiveHour";
        if (isWeekly && (t.includes("all models") || !hasModelQualifier)) {
          return "sevenDay";
        }
        return null;
      }

      const out = { fiveHour: null, sevenDay: null, fetchedAtMillis: Date.now() };
      const progressbars = Array.from(document.querySelectorAll("[role=progressbar][aria-valuenow]"));
      for (const progress of progressbars) {
        const aria = progress.getAttribute("aria-valuenow");
        const utilizationPct = aria != null && Number.isFinite(Number(aria)) ? Number(aria) : null;
        if (utilizationPct == null) continue;
        const labelled = labellingAncestor(progress);
        if (!labelled) continue;
        const kind = classify(labelled.text);
        if (!kind || out[kind]) continue;
        const resetsAtMillis = findResetMillis(labelled.node);
        if (resetsAtMillis == null) continue;
        out[kind] = { utilizationPct, resetsAtMillis };
      }

      return JSON.stringify(out);
    })();
    """
}

/// Reads claude.ai cookies from an account web usage profile.
@MainActor
enum ClaudeWebSession {
    /// Returns true if a session-looking cookie exists for claude.ai.
    static func isConnected(dataStore: WKWebsiteDataStore) async -> Bool {
        let store = dataStore.httpCookieStore
        let cookies = await store.allCookies()
        return cookies.contains {
            $0.domain.hasSuffix("claude.ai") &&
            ($0.name.lowercased().contains("session") || $0.name.lowercased().contains("auth"))
        }
    }

    /// Returns (cookieName, value) pairs for claude.ai (diagnostics).
    static func sessionSummary(dataStore: WKWebsiteDataStore) async -> [String: String] {
        let cookies = await dataStore.httpCookieStore.allCookies()
        var out: [String: String] = [:]
        for c in cookies where c.domain.hasSuffix("claude.ai") {
            out[c.name] = "\(c.value.prefix(8))…"
        }
        return out
    }

    /// Clears all claude.ai cookies for the web usage session.
    static func clear(dataStore: WKWebsiteDataStore) async {
        let store = dataStore.httpCookieStore
        let cookies = await store.allCookies()
        for c in cookies where c.domain.hasSuffix("claude.ai") {
            await store.deleteCookie(c)
        }
    }
}
