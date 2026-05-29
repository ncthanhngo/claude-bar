import SwiftUI
import WebKit

/// Floating-window content for [[QuickReloginCoordinator]].
///
/// Layout: status banner + embedded WKWebView running the Claude Code OAuth
/// authorize page + footer with a "Use Terminal instead" escape hatch that
/// hands back to the legacy [[LoginCoordinator]] flow.
struct QuickReloginSheet: View {
    @EnvironmentObject var coordinator: QuickReloginCoordinator

    let initialURL: URL
    let dataStore: WKWebsiteDataStore

    @State private var currentURL: URL?
    @State private var isLoading = false
    @State private var pageTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner
            Divider()
            webView
            Divider()
            footer
        }
        .frame(width: 720, height: 720)
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusText)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var statusIcon: some View {
        Group {
            switch coordinator.step {
            case .loading, .awaitingConsent:
                Image(systemName: "lock.fill").foregroundColor(.blue)
            case .exchanging, .ingesting:
                Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.blue)
            case .done:
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            case .failed, .identityMismatch:
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            }
        }
        .font(.system(size: 14))
    }

    private var statusText: String {
        switch coordinator.step {
        case .loading:
            return "Opening claude.ai sign-in…"
        case .awaitingConsent:
            return "Authorizing… sign in if Anthropic prompts you."
        case .exchanging:
            return "Exchanging authorization code for tokens…"
        case .ingesting:
            return "Writing credentials to Keychain…"
        case .done(let name, let live):
            return "Re-logged \(name). \(live ? "Live slot updated — Claude Code is ready." : "Backup updated; switch to use it.")"
        case .failed(let msg):
            return "Failed: \(msg)"
        case .identityMismatch(let signedIn, let expected):
            return "Signed in as \(signedIn) but this row is \(expected). Cancel and re-run, picking the right Anthropic account."
        }
    }

    private var webView: some View {
        // OAuthAuthCodeWebView watches every page-load completion and runs a
        // small JS snippet to look for the `<code>#<state>` string Anthropic
        // renders on the "Authentication Code" page (the same string Claude
        // Code CLI normally asks the user to paste into the terminal). When
        // it finds it, we exchange the code automatically — no manual copy
        // step. The legacy redirect-callback path stays wired below as a
        // safety net in case Anthropic ever migrates to an auto-redirect
        // flow, but is not exercised today.
        OAuthAuthCodeWebView(
            initialURL: initialURL,
            dataStore: dataStore,
            pageTitle: $pageTitle,
            isLoading: $isLoading,
            currentURL: $currentURL,
            onCodeDetected: { joined in
                Task { @MainActor in
                    await coordinator.handleManualAuthCode(joined)
                }
            }
        )
        .overlay(alignment: .topTrailing) {
            consentBannerTrigger
        }
        .overlay {
            successOverlay
        }
    }

    /// Opaque success panel that covers the WebView the moment the OAuth
    /// dance finishes. Without it the embedded "Authentication Code — paste
    /// this into Claude Code" page stays visible behind a one-line banner,
    /// reading as "you still have a step to do" when in fact re-login already
    /// succeeded. The panel makes the success state unmistakable and then
    /// auto-closes the window so the stale page never reappears.
    @ViewBuilder
    private var successOverlay: some View {
        if case let .done(name, live) = coordinator.step {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.green)
                Text("Signed in successfully")
                    .font(.system(size: 20, weight: .semibold))
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Text(live
                    ? "Live slot updated — Claude Code is ready."
                    : "Backup updated — switch to this account to use it.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { coordinator.dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .transition(.opacity)
            .task {
                // Linger long enough to read the result, then close so the
                // user lands back on their accounts list rather than a dead
                // OAuth page.
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                coordinator.dismiss()
            }
        }
    }

    /// Empty overlay that flips the status banner to `.awaitingConsent`
    /// once claude.ai has rendered any page in the WebView — gives the user
    /// a hint that the system is waiting for their click rather than still
    /// loading the initial URL.
    private var consentBannerTrigger: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: currentURL?.absoluteString ?? "") {
                guard let url = currentURL else { return }
                if case .loading = coordinator.step,
                   url.host?.contains("claude.ai") == true {
                    Task { @MainActor in
                        coordinator.step = .awaitingConsent
                    }
                }
            }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let acc = coordinator.account {
                    Text(acc.displayName)
                        .font(.system(size: 11, weight: .medium))
                    Text(acc.email)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Use Terminal flow instead") {
                coordinator.switchToTerminalFlow()
            }
            .controlSize(.small)
            Button(closeButtonLabel) { coordinator.dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var closeButtonLabel: String {
        switch coordinator.step {
        case .done: return "Done"
        default: return "Cancel"
        }
    }
}

/// Dedicated WKWebView for the Quick re-login OAuth flow.
///
/// Differs from the shared `ClaudeWebView` in one critical way: after every
/// page-load completion (and for a brief polling window after, to catch
/// React/SPA hydration), it runs a small JS snippet that scans the rendered
/// DOM for the `<code>#<state>` string Anthropic's "Authentication Code"
/// page displays. When found, the joined string is reported via
/// `onCodeDetected` so the coordinator can split/validate/exchange it
/// without forcing the user to copy/paste the way `claude /login` does.
///
/// Kept inside `QuickReloginSheet.swift` rather than promoted to a shared
/// util because the DOM scan logic is specific to Anthropic's CLI OAuth
/// flow — every other WKWebView in the app loads claude.ai chat / usage
/// pages that have no such code element.
private struct OAuthAuthCodeWebView: NSViewRepresentable {
    let initialURL: URL
    let dataStore: WKWebsiteDataStore
    @Binding var pageTitle: String
    @Binding var isLoading: Bool
    @Binding var currentURL: URL?
    let onCodeDetected: (String) -> Void

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
        let parent: OAuthAuthCodeWebView
        private var lastDetected: String?
        private var didAuthorize = false
        private var pollTask: Task<Void, Never>?

        init(parent: OAuthAuthCodeWebView) { self.parent = parent }

        func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            Task { @MainActor in parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = false
                parent.pageTitle = webView.title ?? ""
                parent.currentURL = webView.url
            }
            schedulePoll(webView)
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            Task { @MainActor in parent.isLoading = false }
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            Task { @MainActor in parent.isLoading = false }
        }

        /// Run the DOM scan immediately and then a few more times over ~5s
        /// to catch the auth code element appearing after SPA hydration.
        /// Cancels any in-flight poll first so consecutive navigations don't
        /// stack up parallel polls.
        private func schedulePoll(_ webView: WKWebView) {
            pollTask?.cancel()
            pollTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0..<20 {
                    // Click "Authorize" the moment the consent screen renders so
                    // the user doesn't have to — when already signed into
                    // claude.ai (cookies reused from the web-usage store) this
                    // turns the whole flow into a single right-click → done. If
                    // the page is still a sign-in form there is no Authorize
                    // button, so nothing fires and the user signs in manually;
                    // the next navigation re-arms this poll for the consent page.
                    if !didAuthorize { attemptAutoAuthorize(webView) }
                    scanForCode(webView)
                    if lastDetected != nil { return }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }

        /// Injects a one-shot click on the consent screen's "Authorize" button.
        /// Scoped to the `/oauth/authorize` page and an exact "Authorize" text
        /// match (deny/cancel controls are explicitly skipped) so it can never
        /// click the wrong control or fire on the sign-in form. The post-exchange
        /// identity guard in [[QuickReloginCoordinator]] remains the backstop
        /// against authorizing the wrong Anthropic account.
        private func attemptAutoAuthorize(_ webView: WKWebView) {
            webView.evaluateJavaScript(Self.authorizeScript) { [weak self] result, _ in
                guard let self else { return }
                guard (result as? String) == "clicked" else { return }
                self.didAuthorize = true
                DiagnosticsLogger.shared.log(.info, subsystem: "relogin", "auto-clicked Authorize")
            }
        }

        private func scanForCode(_ webView: WKWebView) {
            webView.evaluateJavaScript(Self.scanScript) { [weak self] result, _ in
                guard let self else { return }
                guard let str = result as? String, !str.isEmpty else { return }
                guard str != self.lastDetected else { return }
                self.lastDetected = str
                let detected = str
                Task { @MainActor in self.parent.onCodeDetected(detected) }
            }
        }

        /// Searches every visible textual element for a base64url-ish
        /// `<code>#<state>` string. Conservative pattern — must be long
        /// enough to plausibly be a real auth code (>= 32 chars before the
        /// `#` and >= 16 chars after) so transient page strings containing
        /// `#` (anchor URLs, hashes in error messages) don't false-positive.
        private static let scanScript = """
        (function() {
          const pat = /\\b([A-Za-z0-9_\\-]{32,})#([A-Za-z0-9_\\-]{16,})\\b/;
          const seen = new Set();
          const candidates = document.querySelectorAll(
            'input, textarea, code, pre, [class*="code"], [class*="Code"], [data-testid*="code"]'
          );
          for (const el of candidates) {
            const val = (el.value || el.innerText || el.textContent || '').trim();
            if (!val || seen.has(val)) continue;
            seen.add(val);
            const m = val.match(pat);
            if (m) return m[0];
          }
          // Fallback: scan body innerText as a single string so we still find
          // the code if Anthropic uses a custom element class.
          const body = (document.body && document.body.innerText) || '';
          const m = body.match(pat);
          return m ? m[0] : null;
        })();
        """

        /// Finds and clicks the consent screen's primary "Authorize" button.
        /// Only runs on the `/oauth/authorize` path; matches a clickable element
        /// whose visible text is exactly "Authorize"/"Authorise" (deny/cancel
        /// words are excluded). Returns "clicked" once it fires, else null so
        /// the poller keeps trying until the consent button appears.
        private static let authorizeScript = """
        (function() {
          if (!/\\/oauth\\/authorize/.test(location.pathname)) return null;
          const wanted = ['authorize', 'authorise'];
          const deny = ['cancel', 'deny', 'reject', 'go back', 'back', 'not now'];
          const els = document.querySelectorAll('button, [role="button"], a[href], input[type="submit"]');
          for (const el of els) {
            if (el.disabled) continue;
            const t = (el.innerText || el.value || el.textContent || '').trim().toLowerCase();
            if (!t || deny.includes(t)) continue;
            if (wanted.includes(t) || wanted.some(w => t.startsWith(w + ' '))) {
              el.click();
              return 'clicked';
            }
          }
          return null;
        })();
        """
    }
}

