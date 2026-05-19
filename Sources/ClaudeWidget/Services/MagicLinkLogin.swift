import Foundation
import WebKit
import AppKit

/// Drives the "login claude CLI via magic link" flow end-to-end.
///
/// Sequence:
///  1. Load the user's magic-link URL in a hidden WKWebView → claude.ai
///     sets `sessionKey` cookie on the WebKit data store.
///  2. Spawn `claude` CLI as subprocess; capture stdout looking for the
///     OAuth URL (PKCE code_challenge embedded in query).
///  3. Navigate the same WKWebView to the captured OAuth URL. The cookie
///     auto-authorizes the request → claude.ai redirects to
///     `http://localhost:<port>/callback?code=...`.
///  4. WKWebView hits the localhost callback → claude CLI receives the
///     code → exchanges it for OAuth tokens → writes Keychain.
///  5. External `KeychainWatcher` detects the Keychain change → calls
///     `markSuccess()` to flip our published status.
@MainActor
final class MagicLinkLogin: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case loadingMagicLink
        case spawningCli
        case waitingForOAuthURL
        case completingOAuth
        case waitingForCallback
        case success
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var detectedEmail: String?
    @Published private(set) var debugTail: String = ""
    @Published private(set) var capturedSessionKey: String?
    @Published private(set) var capturedOrgId: String?

    private var webView: WKWebView!
    private var claudeProcess: Process?
    private var stdoutBuffer = ""
    private var oauthURLFound = false
    private var navContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        let cfg = WKWebViewConfiguration()
        // Ephemeral store — don't pollute the user's existing claude.ai web
        // session managed by WebSessionClient.
        cfg.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = self
    }

    // MARK: - Public entry points

    func start(magicLinkURL url: URL) async {
        detectedEmail = decodeEmail(from: url)

        status = .loadingMagicLink
        do {
            try await navigate(to: url)
            // Give claude.ai JS time to call /api/auth/magic-link and set
            // the sessionKey cookie before we move on.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        } catch {
            return fail("Magic link load failed: \(error.localizedDescription)")
        }

        guard let sessionKey = await readSessionKeyCookie() else {
            return fail("Magic link did not set a sessionKey cookie. The link may be expired or already used.")
        }
        capturedSessionKey = sessionKey
        // Best-effort org detection — fail soft if it errors; polling can still
        // be set up later via "Connect to claude.ai" for this account.
        if let orgId = try? await WebUsageService.validateAndDetectOrg(sessionKey: sessionKey) {
            capturedOrgId = orgId
        }
        // Restore the active account's cookie so other widget paths aren't disrupted.
        if let saved = WebUsageService.loadSessionKey() {
            await WebSessionClient.shared.setSessionKey(saved)
        }

        guard let claudePath = ClaudeBinaryLocator.find() else {
            return fail("Couldn't locate `claude` binary. Install via `npm i -g @anthropic-ai/claude-code`.")
        }

        status = .spawningCli
        runLogoutBlocking(claudePath: claudePath)

        status = .waitingForOAuthURL
        do {
            try spawnClaudeWithStdoutCapture(path: claudePath)
        } catch {
            return fail("Spawn claude failed: \(error.localizedDescription)")
        }

        // Safety: if the CLI never prints an OAuth URL to stdout (TTY issue,
        // unexpected output format, etc.), fail loudly after 45s rather than
        // letting the wizard hang on the spinner forever.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self else { return }
            if self.status == .waitingForOAuthURL {
                self.fail("Timed out waiting for `claude` to print the OAuth URL. The CLI may need a TTY — try logging in via Terminal manually, then use Add → Snapshot current.")
            }
        }
    }

    func cancel() {
        claudeProcess?.terminate()
        claudeProcess = nil
    }

    /// Called by the wizard when KeychainWatcher detects fresh OAuth tokens.
    func markSuccess() {
        status = .success
        claudeProcess?.terminate()
        claudeProcess = nil
    }

    // MARK: - Subprocess

    private func runLogoutBlocking(claudePath: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = ["logout"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    private func spawnClaudeWithStdoutCapture(path: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = []  // bare `claude` triggers interactive login when no creds

        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = stdout

        let stdin = Pipe()
        p.standardInput = stdin

        // Regex catches both `claude.ai/oauth?...` and `claude.ai/login?...`
        // patterns that include a code_challenge param.
        let regex = try NSRegularExpression(
            pattern: #"https://claude\.ai/(?:oauth|login)[^\s"']+code_challenge=[^\s"']+"#,
            options: []
        )

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.processStdoutChunk(chunk, regex: regex) }
        }

        try p.run()
        claudeProcess = p
    }

    private func processStdoutChunk(_ chunk: String, regex: NSRegularExpression) {
        stdoutBuffer += chunk
        debugTail = String(stdoutBuffer.suffix(400))

        guard !oauthURLFound else { return }
        let range = NSRange(stdoutBuffer.startIndex..., in: stdoutBuffer)
        guard let match = regex.firstMatch(in: stdoutBuffer, range: range),
              let r = Range(match.range, in: stdoutBuffer) else { return }
        let urlString = String(stdoutBuffer[r])
        guard let url = URL(string: urlString) else { return }
        oauthURLFound = true
        Task { await completeOAuth(url: url) }
    }

    private func completeOAuth(url: URL) async {
        status = .completingOAuth
        do {
            try await navigate(to: url)
            status = .waitingForCallback
            // From here we wait for the keychain watcher (external) to fire.
        } catch {
            fail("OAuth navigation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - WKWebView helpers

    private func navigate(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.navContinuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    private func readSessionKeyCookie() async -> String? {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        return cookies.first {
            $0.name == "sessionKey" && $0.domain.contains("claude.ai") && !$0.value.isEmpty
        }?.value
    }

    // MARK: - Helpers

    private func decodeEmail(from url: URL) -> String? {
        MagicLinkParser.decodeEmail(from: url)
    }

    private func fail(_ message: String) {
        status = .failed(message)
        cancel()
    }
}

// MARK: - WKNavigationDelegate

extension MagicLinkLogin: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.resumeNav(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resumeNav(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // localhost callback failures often mean the local server already
        // handed the code back to the CLI — treat as success-equivalent.
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain &&
           (nsErr.code == NSURLErrorCannotConnectToHost || nsErr.code == NSURLErrorNetworkConnectionLost) {
            Task { @MainActor in self.resumeNav(nil) }
        } else {
            Task { @MainActor in self.resumeNav(error) }
        }
    }

    private func resumeNav(_ error: Error?) {
        guard let cont = navContinuation else { return }
        navContinuation = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }
}
