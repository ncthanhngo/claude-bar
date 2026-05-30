import SwiftUI
import WebKit

enum ClaudeWebUsageError: LocalizedError {
    case usagePageNotReady
    case usageUnavailable
    /// claude.ai returned 429 (Too Many Requests) or 403 (Forbidden) on the
    /// usage navigation. Surfaces a hint so the caller can backoff polling
    /// for that account instead of hammering the same response.
    case rateLimited(status: Int)

    var errorDescription: String? {
        switch self {
        case .usagePageNotReady:
            return "Claude web usage page did not finish loading."
        case .usageUnavailable:
            return "Claude web usage did not expose a 5h or 7d quota window."
        case .rateLimited(let status):
            return "claude.ai blocked the usage request (HTTP \(status))."
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
    /// Status code captured by `decidePolicyFor:NavigationResponse` for the
    /// main-frame response. Surfaces 429 / 403 so the caller can backoff
    /// polling for the offending account instead of hammering the same
    /// rate-limited response. Reset on every `reloadUsagePage`.
    private var lastMainFrameStatus: Int?

    init(dataStore: WKWebsiteDataStore) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func fetchUsage() async throws -> UsageDTO {
        try await reloadUsagePage()
        // Reject 429 / 403 before scraping — claude.ai sometimes still
        // renders a usable-looking shell on rate-limit so DOM scraping
        // would yield empty results that masquerade as "SPA not hydrated".
        // Surfacing the status explicitly lets the coordinator backoff
        // this account instead of retrying every poll cycle.
        if let status = lastMainFrameStatus, status == 429 || status == 403 {
            throw ClaudeWebUsageError.rateLimited(status: status)
        }
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
        var lastRaw: String?
        let maxAttempts = 16            // 16 * 0.5s = 8s ceiling
        let bailIfEmptyAfter = 4        // give up early if SPA never paints
        for attempt in 0..<maxAttempts {
            let result = try await webView.evaluateJavaScript(Self.scrapeScript)
            if let raw = result as? String,
               let data = raw.data(using: .utf8) {
                lastRaw = raw
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
                if let raw = lastRaw {
                    DiagnosticsLogger.shared.log(.warning, subsystem: "web-usage",
                        "scrape diag (bail attempt=\(attempt)) — \(raw.prefix(1200))")
                }
                let pageDiag = await pageDiagnostics()
                DiagnosticsLogger.shared.log(.warning, subsystem: "web-usage",
                    "page diag — \(pageDiag)")
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
        lastMainFrameStatus = nil
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            // Bypass HTTP cache so a recent reset isn't masked by a 304 that
            // re-renders the pre-reset DOM. (Earlier I added a `?t=<ms>`
            // cache-bust here as a second belt against service-worker
            // replays, but observed that subsequent loads then returned 0
            // progressbars where a fresh load returned 5 — claude.ai may
            // be reading the query string and serving a different bundle.
            // Reverted to the bare URL with just the cache policy override.)
            var request = URLRequest(url: usageURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            webView.load(request)
        }
    }

    /// Snapshot of the loaded page used for diagnostics when the scrape
    /// returns no progressbars — lets us tell "claude.ai rendered a login
    /// page" or "redirected" from "DOM structure changed" without needing
    /// to re-run the widget under a debugger.
    private func pageDiagnostics() async -> String {
        let url = webView.url?.absoluteString ?? "<no url>"
        let title = webView.title ?? "<no title>"
        let bodyJS = "(document.body && document.body.innerText || '').slice(0, 200).replace(/\\s+/g, ' ')"
        let body = (try? await webView.evaluateJavaScript(bodyJS)) as? String ?? "<no body>"
        return "url=\(url) | title=\(title) | bodyPrefix=\(body)"
    }

    nonisolated func webView(_: WKWebView,
                             decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Capture the main-frame HTTP status so fetchUsage() can detect
        // rate limiting (429) and outright blocks (403) before falling
        // into the JS scrape loop. Subresources (XHR, fonts, CSS) are
        // ignored — only the page navigation matters for backoff.
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            let status = http.statusCode
            Task { @MainActor [weak self] in
                self?.lastMainFrameStatus = status
            }
        }
        decisionHandler(.allow)
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
          // Skip empty wrappers (the progressbar's immediate parent often
          // has no innerText of its own — bailing here used to abort the
          // whole walk before reaching the labelling row). Only break on
          // the over-large guard so we don't walk past the usage section
          // into page-wide containers.
          if (text.length > 900) break;
          if (!text) continue;
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
        const isAllModels = /all\\s+models/.test(t);
        const isSession = /current\\s+session|5\\s*-?\\s*hour/.test(t);
        // Ambiguous outer wrapper containing both window labels — refuse to
        // guess. A subsequent progressbar should find a tighter labelling
        // ancestor; if none does we surface UnavailableBar instead of wrong.
        if (isSession && (isWeekly || isAllModels)) return null;
        if (isSession) return "fiveHour";
        const hasModelQualifier = /\\b(opus|sonnet|haiku)\\b/.test(t);
        // "All models" alone is the canonical weekly headline bar on
        // current claude.ai — its label cell does NOT include the
        // "Weekly limits" heading text (which lives one section up).
        // Treat all-models without a per-model qualifier as sevenDay even
        // when "weekly" itself isn't in the cell.
        if ((isWeekly || isAllModels) && !hasModelQualifier) {
          return "sevenDay";
        }
        return null;
      }

      // Pull the percentage from the visible "X% used" text inside the
      // labelling cell — that's the number the user actually reads. The
      // page's `aria-valuenow` is not on a 0-100 scale (we have observed
      // values that diverge ~2x from the rendered percentage, both above
      // and below, e.g. 14 vs 7 % and 52 vs 59 %), so trusting it directly
      // gave wrong quota numbers for every web-linked account. We still
      // fall back to (aria-valuenow / aria-valuemax) when no "% used"
      // string is present so a future markup change degrades gracefully
      // instead of dropping the window entirely.
      function readPct(progress, labelText) {
        const m = (labelText || "").match(/(\\d+(?:\\.\\d+)?)\\s*%\\s*used/i)
              || (labelText || "").match(/(\\d+(?:\\.\\d+)?)\\s*%/);
        if (m) {
          const pct = Number(m[1]);
          if (Number.isFinite(pct) && pct >= 0 && pct <= 100) return pct;
        }
        const now = Number(progress.getAttribute("aria-valuenow"));
        if (!Number.isFinite(now)) return null;
        const maxAttr = progress.getAttribute("aria-valuemax");
        const max = Number(maxAttr);
        const denom = Number.isFinite(max) && max > 0 ? max : 100;
        const pct = (now / denom) * 100;
        return Number.isFinite(pct) ? Math.max(0, Math.min(100, pct)) : null;
      }

      // Sensible future fallback when the reset clause is unparseable
      // (e.g., claude.ai sometimes prints "Resets Fri 7:00 PM" or a
      // localised date format the regex below doesn't cover). Without a
      // future `resetsAt`, downstream Swift drops the result via
      // `hasPastResetWindow`, so a single DOM-format change wipes out the
      // entire scrape. Returning a fallback at least keeps the percentage
      // flowing — the countdown will be approximate until the next
      // successful poll, but the usage bar updates.
      function fallbackReset(kind) {
        const now = Date.now();
        return kind === "fiveHour" ? now + 5 * 60 * 60 * 1000
                                   : now + 7 * 24 * 60 * 60 * 1000;
      }

      const out = { fiveHour: null, sevenDay: null, fetchedAtMillis: Date.now(), diag: { progressbarCount: 0, samples: [] } };
      const progressbars = Array.from(document.querySelectorAll("[role=progressbar][aria-valuenow]"));
      out.diag.progressbarCount = progressbars.length;
      for (const progress of progressbars) {
        const labelled = labellingAncestor(progress);
        const aria = progress.getAttribute("aria-valuenow");
        if (out.diag.samples.length < 6) {
          // Walk all 8 ancestors and report what each one contains, so we
          // can see exactly where the label / reset text lives relative to
          // the progressbar. The labellingAncestor function above breaks
          // on `length > 900` and only sets `best` when both patterns
          // are present — if claude.ai's wrapper exceeds that, we get
          // null even though the data is right there in a deeper or
          // shallower ancestor.
          const ancestors = [];
          let node = progress.parentElement;
          for (let d = 0; d < 8 && node; d++, node = node.parentElement) {
            const text = (node.innerText || node.textContent || "").trim();
            ancestors.push({
              d,
              len: text.length,
              hasLabel: /current\\s+session|5\\s*-?\\s*hour|weekly|all\\s+models|7\\s*-?\\s*day/i.test(text),
              hasReset: /reset/i.test(text),
              hasPct: /\\d+\\s*%/.test(text),
              snippet: text.slice(0, 80).replace(/\\s+/g, " ")
            });
          }
          out.diag.samples.push({
            aria,
            hasLabel: !!labelled,
            label: labelled ? labelled.text.slice(0, 120).replace(/\\s+/g, " ") : null,
            ancestors
          });
        }
        if (!labelled) continue;
        const kind = classify(labelled.text);
        if (!kind || out[kind]) continue;
        const utilizationPct = readPct(progress, labelled.text);
        if (utilizationPct == null) continue;
        const parsed = findResetMillis(labelled.node);
        const resetsAtMillis = parsed != null ? parsed : fallbackReset(kind);
        out[kind] = { utilizationPct, resetsAtMillis, resetParsed: parsed != null };
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
