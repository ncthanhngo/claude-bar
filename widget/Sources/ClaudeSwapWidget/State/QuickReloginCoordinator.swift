import AppKit
import Foundation
import SwiftUI
import WebKit

/// In-app WebView re-login flow for an existing account.
///
/// Shortens the Terminal → browser → CLI path that `LoginCoordinator` drives
/// (still kept as the canonical recovery) to a single embedded WKWebView:
/// 1. Generate PKCE pair + random `state`.
/// 2. Load `claude.ai/oauth/authorize` for the Claude Code CLI's client_id.
/// 3. Intercept the redirect to `console.anthropic.com/oauth/code/callback`.
/// 4. Exchange the `code` for an OAuth payload at `platform.claude.com`.
/// 5. Read the signed-in email from the token-exchange response and confirm
///    it matches the account the user right-clicked — refuses to overwrite
///    Account-A's tokens when the consent screen authorised Account-B.
/// 6. Pipe the payload to `csw ingest-oauth` (writes backup + live slot).
///
/// All UI lives in [[QuickReloginSheet]]. The Terminal-based "Add account"
/// flow [[LoginCoordinator]] is unchanged and remains the recommended path
/// when this shortcut breaks (e.g. Anthropic alters the authorize URL).
@MainActor
final class QuickReloginCoordinator: ObservableObject {
    enum Step: Equatable {
        case loading                      // WebView is loading the authorize URL
        case awaitingConsent              // User is interacting with claude.ai
        case exchanging                   // Got code; calling token endpoint
        case ingesting                    // Calling csw ingest-oauth
        case done(displayName: String, wroteLive: Bool)
        case failed(String)
        case identityMismatch(signedInAs: String, expectedEmail: String)
    }

    @Published var step: Step = .loading
    @Published private(set) var account: AccountDTO?

    private let window = FloatingWindow<AnyView>()
    private weak var store: AppStore?
    private weak var webFallback: WebFallbackCoordinator?
    private weak var loginCoordinator: LoginCoordinator?

    // Stateless OAuth primitives (authorize URL, PKCE, token exchange).
    private let engine = OAuthLoginEngine()
    // The PKCE pair + `state` for the current attempt; nil between attempts and
    // consumed atomically on first use so a replayed DOM scan can't double-exchange.
    private var attempt: OAuthLoginEngine.Attempt?
    private var dataStore: WKWebsiteDataStore?

    func attach(store: AppStore, webFallback: WebFallbackCoordinator, loginCoordinator: LoginCoordinator) {
        self.store = store
        self.webFallback = webFallback
        self.loginCoordinator = loginCoordinator
    }

    /// Closes the WebView sheet and hands control to the Terminal-based
    /// `claude /login` flow. Invoked from the sheet's "Use Terminal flow
    /// instead" button — kept here rather than as an `@EnvironmentObject`
    /// dependency in the sheet so `QuickReloginSheet` only requires the one
    /// coordinator we explicitly inject when showing the floating window.
    func switchToTerminalFlow() {
        let login = loginCoordinator
        dismiss()
        login?.begin()
    }

    /// Open the floating window and start the OAuth dance for `account`.
    /// Reuses the account's existing web-usage `WKWebsiteDataStore` so users
    /// already signed into claude.ai skip the password step — the sheet then
    /// auto-clicks Authorize and exchanges the code, making re-login a single
    /// right-click. Users not yet signed in just enter credentials once; the
    /// Authorize click is still automated afterwards.
    func begin(for account: AccountDTO) {
        self.account = account
        self.step = .loading
        let attempt = OAuthLoginEngine.Attempt()
        self.attempt = attempt
        guard let url = engine.buildAuthorizeURL(attempt) else {
            self.step = .failed("Could not build authorize URL.")
            return
        }
        // Reuse the per-account WKWebsiteDataStore so any existing claude.ai
        // sign-in (linked via the web usage flow) carries over and lets the
        // user complete consent in one click.
        self.dataStore = webFallback?.dataStoreForReuse(account: account)

        window.show(
            title: "Re-login — \(account.displayName)",
            size: NSSize(width: 720, height: 720)
        ) {
            AnyView(
                // Fallback to a NON-persistent store when the per-account
                // identifier can't be resolved (rare — registry mid-write).
                // Using `.default()` here would write claude.ai cookies into
                // the system-wide shared store and leak the session across
                // every Claude Bar account; non-persistent dies with the
                // sheet at the cost of forcing the user to type credentials
                // for this single attempt.
                QuickReloginSheet(
                    initialURL: url,
                    dataStore: self.dataStore ?? .nonPersistent()
                )
                .environmentObject(self)
            )
        }
        window.onClose = { [weak self] in
            // User closed the window mid-flow — drop any in-flight state.
            self?.attempt = nil
        }
    }

    func dismiss() {
        window.close()
        attempt = nil
    }

    /// Called when the embedded WebView's DOM scan finds the rendered
    /// "Authentication Code" page Anthropic's OAuth server shows after the
    /// user clicks Authorize. The code on that page is the `<code>#<state>`
    /// concatenation Claude Code CLI normally asks the user to paste into
    /// the terminal — we split it, validate the state, and drive the rest
    /// of the flow without making the user copy/paste.
    func handleManualAuthCode(_ joined: String) async {
        guard let current = attempt else { return }
        // Consume the attempt atomically so a second DOM scan (page re-renders
        // its input, React hydration replays) cannot trigger a duplicate
        // exchange with the same code.
        attempt = nil
        let expectedState = current.state
        let verifier = current.verifier

        DiagnosticsLogger.shared.log(.info, subsystem: "relogin",
            "captured auth code len=\(joined.count) hasHash=\(joined.contains("#")) prefix=\(joined.prefix(8))…")
        let parts = joined.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            step = .failed("Auth code format unexpected (no `#` separator).")
            return
        }
        let code = parts[0]
        let receivedState = parts[1]
        guard receivedState == expectedState else {
            step = .failed("OAuth state mismatch — refusing to use this code.")
            return
        }

        step = .exchanging
        do {
            let payload = try await engine.exchangeCode(code: code, state: receivedState, verifier: verifier)
            try await ingest(payload: payload)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    /// Legacy redirect-callback path. Kept as a safety net in case Anthropic
    /// ever migrates the CLI OAuth client to a machine-readable redirect_uri
    /// — current Claude Code flow renders the manual-paste page instead, so
    /// this path is not exercised today.
    func handleRedirect(_ url: URL) async {
        guard let current = attempt else { return }
        // Consume the attempt immediately so a second navigation to the
        // callback URL (back-button, redirect chain replay) cannot trigger
        // a second exchange with the same code — the token endpoint would
        // return 400 and the sheet would surface a `.failed` state for what
        // is actually a succeeded flow.
        attempt = nil
        let expectedState = current.state
        let verifier = current.verifier
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else {
            step = .failed("Callback URL is missing query parameters.")
            return
        }
        let code = items.first { $0.name == "code" }?.value
        let receivedState = items.first { $0.name == "state" }?.value
        let errorParam = items.first { $0.name == "error" }?.value
        if let errorParam {
            step = .failed("Anthropic rejected the authorization: \(errorParam).")
            return
        }
        guard let code, !code.isEmpty else {
            step = .failed("Callback URL did not include an authorization code.")
            return
        }
        guard let receivedState, receivedState == expectedState else {
            step = .failed("OAuth state mismatch — refusing to use this code.")
            return
        }

        step = .exchanging
        do {
            let payload = try await engine.exchangeCode(code: code, state: receivedState, verifier: verifier)
            try await ingest(payload: payload)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    private func ingest(payload: OAuthLoginEngine.ExchangedToken) async throws {
        guard let account, let store else {
            step = .failed("Internal error: no target account.")
            return
        }
        step = .ingesting

        // Identity guard. Only enforce when the JWT actually exposed an
        // email; some access_token shapes are opaque, in which case we let
        // the user proceed (the backend still verifies the account exists).
        if let signedIn = payload.signedInEmail,
           signedIn.lowercased() != account.email.lowercased() {
            step = .identityMismatch(signedInAs: signedIn, expectedEmail: account.email)
            return
        }

        do {
            let res = try await store.client.ingestOAuth(
                accountNum: account.number,
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                expiresAt: payload.expiresAt,
                scopes: payload.scopes,
                subscriptionType: nil,
                expectedEmail: payload.signedInEmail
            )
            await store.refreshNow()
            // When the rewritten account was already active, the running
            // `claude` CLI is still holding the now-superseded tokens in
            // memory. Trigger the same post-swap pipeline a normal swap uses
            // — claude-watch SIGINT → `claude --resume <sid>` keeps the
            // conversation; cmux panes get the same treatment via
            // CmuxPaneRelauncher; IDE windows reload if the user has the
            // toggle on. Inactive re-login skips this since no live CLI is
            // affected.
            if res.wroteLive {
                store.schedulePostSwapIntegrations()
            }
            step = .done(displayName: res.account.displayName, wroteLive: res.wroteLive)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

}

extension WebFallbackCoordinator {
    /// Returns (creating if needed) the per-account WKWebsiteDataStore that
    /// the web-usage flow already manages. Sharing it with the OAuth re-login
    /// flow means a user already signed into claude.ai for usage scraping
    /// gets a one-click Authorize instead of being asked to log in twice.
    func dataStoreForReuse(account: AccountDTO) -> WKWebsiteDataStore? {
        linkedDataStorePublic(for: account, createIfNeeded: true)
    }
}
