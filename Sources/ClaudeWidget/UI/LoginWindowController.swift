import AppKit
import WebKit

/// Opens a Safari-like sign-in window pointed at `claude.ai/login`.
/// Watches the shared cookie store; resolves with the `sessionKey` value as
/// soon as Anthropic sets it (any login provider — email, Google, Apple, etc.).
@MainActor
final class LoginWindowController: NSObject {

    enum LoginError: LocalizedError {
        case cancelled
        case timeout
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Login cancelled."
            case .timeout:   return "Login timed out."
            }
        }
    }

    // Anthropic + supported IdPs only.
    nonisolated private static let allowedHosts: [String] = [
        "claude.ai",
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
        "anthropic.com",
        "console.anthropic.com"
    ]

    private var window: NSWindow!
    private var webView: WKWebView!
    private var continuation: CheckedContinuation<String, Error>?
    private static var retain: LoginWindowController?

    /// Static entry point — keeps the controller alive until the flow finishes.
    static func runFlow() async throws -> String {
        let ctrl = LoginWindowController()
        Self.retain = ctrl
        defer { Self.retain = nil }
        return try await ctrl.start()
    }

    // MARK: - Setup

    private func start() async throws -> String {
        // Persistent shared store — same one WebSessionClient reads from.
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore.default()

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: cfg)
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        window.contentView = webView
        window.center()
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isReleasedWhenClosed = false

        // Cookie observer fires whenever Anthropic sets cookies (incl. sessionKey).
        cfg.websiteDataStore.httpCookieStore.add(self)

        // App runs as a menu-bar accessory (`LSUIElement=true`). NSWindows
        // from accessory apps don't get focus by default — temporarily switch
        // to `.regular` so the login window becomes the front-most app window.
        let previousPolicy = NSApp.activationPolicy()
        previousActivationPolicy = previousPolicy
        if previousPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        NSLog("ClaudeWidget: login window opened, loading claude.ai/login")
        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }
    }

    /// Snapshot of the app's activation policy before we forced `.regular`.
    private var previousActivationPolicy: NSApplication.ActivationPolicy?

    private func restoreActivationPolicy() {
        if let prev = previousActivationPolicy, prev != NSApp.activationPolicy() {
            NSApp.setActivationPolicy(prev)
        }
        previousActivationPolicy = nil
    }

    // MARK: - Helpers

    fileprivate func resolve(with value: String) {
        guard let cont = continuation else { return }
        continuation = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        NSLog("ClaudeWidget: sessionKey captured, closing login window")
        window?.close()
        restoreActivationPolicy()
        cont.resume(returning: value)
    }

    fileprivate func reject(with error: Error) {
        guard let cont = continuation else { return }
        continuation = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        restoreActivationPolicy()
        NSLog("ClaudeWidget: login rejected: \(error.localizedDescription)")
        cont.resume(throwing: error)
    }

    fileprivate func handleCookieChange() {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            guard let sk = cookies.first(where: {
                $0.name == "sessionKey" && $0.domain.contains("claude.ai") && !$0.value.isEmpty
            }) else { return }
            Task { @MainActor in self.resolve(with: sk.value) }
        }
    }
}

// MARK: - Cookie observer

extension LoginWindowController: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.handleCookieChange() }
    }
}

// MARK: - Navigation gate

extension LoginWindowController: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        guard let host = url?.host?.lowercased() else {
            decisionHandler(.allow); return
        }
        let allowed = LoginWindowController.allowedHosts.contains { d in
            host == d || host.hasSuffix("." + d)
        }
        if !allowed { NSLog("ClaudeWidget: blocking nav to \(host)") }
        decisionHandler(allowed ? .allow : .cancel)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Some IdP flows set the cookie via JS — re-check on each finished nav.
        Task { @MainActor in self.handleCookieChange() }
    }
}

// MARK: - Window lifecycle

extension LoginWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if self.continuation != nil { self.reject(with: LoginError.cancelled) }
        }
    }
}
