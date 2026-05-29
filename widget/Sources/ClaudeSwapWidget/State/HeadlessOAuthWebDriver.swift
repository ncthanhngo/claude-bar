import Foundation
import WebKit

/// Drives a bare, unparented `WKWebView` through the Claude Code OAuth
/// authorize page without showing any window to the user.
///
/// Hosting strategy mirrors `ClaudeWebUsageFetcher`: the WebView is created
/// with `frame: .zero`, never added to a view hierarchy or window, and driven
/// purely via `evaluateJavaScript` on a native poll. Window occlusion and
/// AppKit throttling are irrelevant because there is no on-screen layer.
///
/// Lifecycle: create → `start()` → one of (`onCode`, `onNeedsManualSignIn`)
/// fires at most once → `cancel()` tears down the WebView. The coordinator's
/// 30-second timeout calls `cancel()` if neither callback fires in time,
/// guaranteeing the `beginHeadless` continuation always resumes.
@MainActor
final class HeadlessOAuthWebDriver: NSObject, WKNavigationDelegate {

    // MARK: - Callbacks (single-fire)

    /// Fires when the DOM scan finds a `code#state` string on the authorize
    /// page. The full joined string is passed to the coordinator for splitting,
    /// state validation, and token exchange.
    var onCode: ((String) -> Void)?

    /// Fires when a login-form page is positively detected (password field
    /// present at a login-path URL), indicating the session cookies are gone
    /// and the user must sign in interactively.
    var onNeedsManualSignIn: (() -> Void)?

    // MARK: - Internals

    private let webView: WKWebView
    private let authorizeURL: URL

    /// Guards both callbacks so each fires at most once even if the poll
    /// races a navigation event or cancel() is called concurrently.
    private var fired = false

    /// Tracks navigations that completed without yielding a code, used to
    /// bound the manual-sign-in probe: only probe after at least one full
    /// page load so we don't false-positive on the blank initial state.
    private var navigationCount = 0

    private var pollTask: Task<Void, Never>?

    // MARK: - Init

    init(authorizeURL: URL, dataStore: WKWebsiteDataStore) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        // Unparented, zero-frame WebView — never added to any window/view.
        // The WKWebView retains itself through its internal layer tree, so
        // holding a strong reference here keeps it alive for the driver's
        // lifetime without any additional retain tricks.
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.authorizeURL = authorizeURL
        super.init()
        self.webView.navigationDelegate = self
    }

    // MARK: - Public interface

    func start() {
        webView.load(URLRequest(url: authorizeURL))
        DiagnosticsLogger.shared.log(.info, subsystem: "relogin-headless",
            "loading \(authorizeURL.absoluteString)")
    }

    /// Tears down the poll and releases the WebView's navigation delegate so
    /// it can be deallocated. Safe to call multiple times.
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        DiagnosticsLogger.shared.log(.info, subsystem: "relogin-headless", "cancelled")
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        Task { @MainActor [weak self] in self?.didFinishNavigation(webView) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        DiagnosticsLogger.shared.log(.warning, subsystem: "relogin-headless",
            "navigation failed: \(error.localizedDescription)")
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!,
                             withError error: Error) {
        DiagnosticsLogger.shared.log(.warning, subsystem: "relogin-headless",
            "provisional navigation failed: \(error.localizedDescription)")
    }

    // MARK: - Poll

    private func didFinishNavigation(_ webView: WKWebView) {
        navigationCount += 1
        DiagnosticsLogger.shared.log(.info, subsystem: "relogin-headless",
            "didFinish nav=\(navigationCount) url=\(webView.url?.absoluteString ?? "<nil>")")
        schedulePoll(webView)
    }

    /// Runs up to 20 × 250ms polls (5s window) after each navigation:
    /// 1. Auto-click Authorize if the consent button is present.
    /// 2. Scan for the `code#state` string — report via `onCode` and stop.
    /// 3. After the first navigation with no code, check for a login form;
    ///    if confirmed, report via `onNeedsManualSignIn` and stop.
    ///
    /// Cancels any previous poll first so consecutive navigations don't stack
    /// up parallel polls that could emit duplicate callbacks.
    private func schedulePoll(_ webView: WKWebView) {
        pollTask?.cancel()
        let navIndex = navigationCount
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<20 {
                guard !Task.isCancelled, !self.fired else { return }

                // Attempt auto-authorize (no-op on non-authorize pages).
                self.tryAutoAuthorize(webView)

                // Scan for the code#state string rendered after the user
                // (or auto-click) approves the consent screen.
                if await self.scanForCode(webView) { return }

                // Only probe for a login form after at least one full
                // navigation has completed — avoids false-positives on the
                // initial page load before any redirect chain runs.
                if navIndex >= 1 {
                    if await self.probeSignInForm(webView) { return }
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Returns true if the code was found and `onCode` was emitted.
    private func scanForCode(_ webView: WKWebView) async -> Bool {
        guard !fired else { return true }
        let result = try? await webView.evaluateJavaScript(OAuthWebScripts.scanScript)
        guard let str = result as? String, !str.isEmpty else { return false }
        emitOnce {
            DiagnosticsLogger.shared.log(.info, subsystem: "relogin-headless",
                "code found len=\(str.count)")
            self.onCode?(str)
        }
        return true
    }

    /// Returns true if a login form was positively detected and
    /// `onNeedsManualSignIn` was emitted.
    private func probeSignInForm(_ webView: WKWebView) async -> Bool {
        guard !fired else { return true }
        let result = try? await webView.evaluateJavaScript(OAuthWebScripts.signInProbeScript)
        guard (result as? String) == "signin" else { return false }
        emitOnce {
            DiagnosticsLogger.shared.log(.info, subsystem: "relogin-headless",
                "login form detected — needs manual sign-in")
            self.onNeedsManualSignIn?()
        }
        return true
    }

    private func tryAutoAuthorize(_ webView: WKWebView) {
        webView.evaluateJavaScript(OAuthWebScripts.authorizeScript) { result, _ in
            if (result as? String) == "clicked" {
                DiagnosticsLogger.shared.log(.info, subsystem: "relogin-headless",
                    "auto-clicked Authorize")
            }
        }
    }

    /// Executes `body` and sets `fired = true` in one step so concurrent poll
    /// iterations (JS callbacks arrive on a non-main queue then hop to MainActor)
    /// cannot both slip through the `fired` check.
    private func emitOnce(_ body: () -> Void) {
        guard !fired else { return }
        fired = true
        body()
    }
}
