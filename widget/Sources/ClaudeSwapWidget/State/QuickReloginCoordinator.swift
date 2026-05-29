import AppKit
import Foundation
import SwiftUI
import WebKit

/// Terminal, exhaustive result of any re-login attempt (interactive or headless).
///
/// Each case is a dead-end: the caller must act on it and never retry
/// automatically except by starting a fresh attempt through the coordinator.
enum ReloginOutcome {
    /// Token exchange succeeded and credentials were ingested.
    case succeeded(displayName: String, wroteLive: Bool)
    /// Unrecoverable error (network, token endpoint, ingest). Includes a
    /// human-readable reason for diagnostics; may be retried with back-off.
    case failed(String)
    /// A login form appeared instead of the consent screen — the session
    /// cookies are gone and the user must sign in interactively.
    case needsManualSignIn
    /// The exchanged token belongs to a different Anthropic account than the
    /// target row. Terminal: retrying headlessly would repeat the mismatch.
    case identityMismatch(signedInAs: String, expected: String)
}

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

    // Single-flight guard: true while an interactive OR headless attempt is in
    // flight. A second begin/beginHeadless call returns .failed("busy") immediately
    // without touching the in-flight attempt's state.
    private var inFlight = false

    // Reserved hook for an external observer of the interactive flow's terminal
    // result (e.g. resetting a recovery status after a manual re-login).
    // Currently never assigned — `finishInteractive` reads it as nil and the
    // sheet UI is driven by `step` instead. Set it before `begin(for:)` to
    // receive the outcome; it is cleared after firing.
    private var completion: ((ReloginOutcome) -> Void)?

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
        guard !inFlight else {
            DiagnosticsLogger.shared.log(.warning, subsystem: "relogin",
                "begin(for:) ignored — attempt already in flight")
            return
        }
        inFlight = true
        self.account = account
        self.step = .loading
        let attempt = OAuthLoginEngine.Attempt()
        self.attempt = attempt
        guard let url = engine.buildAuthorizeURL(attempt) else {
            self.step = .failed("Could not build authorize URL.")
            finishInteractive(outcome: .failed("Could not build authorize URL."))
            // The window never opened, so window.onClose can't clear the
            // single-flight guard — clear it here or all future re-login
            // (interactive and headless) stays permanently locked out.
            self.attempt = nil
            clearFlight()
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
            self?.clearFlight()
        }
    }

    func dismiss() {
        window.close()
        attempt = nil
        clearFlight()
    }

    // MARK: - Headless entry point

    /// Re-logs in an account invisibly (no window) and returns exactly one
    /// `ReloginOutcome`. The function is guaranteed to return — either via
    /// a code-exchange result or a hard 30-second wall-clock timeout — so
    /// callers can await it unconditionally.
    ///
    /// Single-flight: returns `.failed("busy")` immediately if any other
    /// attempt (interactive or headless) is already in progress.
    func beginHeadless(forAccountNumber accountNum: Int) async -> ReloginOutcome {
        guard !inFlight else {
            DiagnosticsLogger.shared.log(.warning, subsystem: "relogin",
                "beginHeadless ignored — attempt already in flight")
            return .failed("busy")
        }
        guard let snapshot = store?.snapshot,
              let accountView = snapshot.accounts.first(where: { $0.account.number == accountNum }) else {
            return .failed("account \(accountNum) not found in snapshot")
        }
        let targetAccount = accountView.account
        inFlight = true
        defer { clearFlight() }

        let attempt = OAuthLoginEngine.Attempt()
        guard let url = engine.buildAuthorizeURL(attempt) else {
            return .failed("Could not build authorize URL.")
        }
        let ds = webFallback?.dataStoreForReuse(account: targetAccount) ?? .nonPersistent()

        DiagnosticsLogger.shared.log(.info, subsystem: "relogin",
            "headless begin account=\(accountNum) email=\(targetAccount.email)")

        // Drive a headless WKWebView and race it against a 30-second hard timeout.
        // The timeout is the invariant guarantee: even if the JS never fires
        // (throttled renderer, navigation loop), the caller gets exactly one outcome.
        let outcome: ReloginOutcome = await withCheckedContinuation { continuation in
            // Single-fire wrapper so the continuation is resumed exactly once
            // regardless of how many callbacks the driver might emit. Also
            // cancels the timeout Task so a success path doesn't retain the
            // WebView host for the full 30s.
            var fired = false
            var timeoutTask: Task<Void, Never>?
            func emit(_ result: ReloginOutcome) {
                guard !fired else { return }
                fired = true
                timeoutTask?.cancel()
                continuation.resume(returning: result)
            }

            let driver = HeadlessOAuthWebDriver(authorizeURL: url, dataStore: ds)

            driver.onCode = { [weak self] joined in
                guard let self else { emit(.failed("coordinator deallocated")); return }
                Task { @MainActor in
                    let result = await self.exchangeAndIngest(
                        joined: joined,
                        attempt: attempt,
                        account: targetAccount
                    )
                    driver.cancel()
                    emit(result)
                }
            }
            driver.onNeedsManualSignIn = {
                driver.cancel()
                emit(.needsManualSignIn)
            }

            driver.start()

            // 30-second wall-clock timeout. Races the driver callbacks above.
            // If the driver fires first, `emit` cancels this Task. If neither
            // fires within 30s, the timeout wins and the driver is torn down.
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                driver.cancel()
                emit(.failed("timeout"))
            }
        }

        DiagnosticsLogger.shared.log(.info, subsystem: "relogin",
            "headless done account=\(accountNum) outcome=\(outcome)")
        return outcome
    }

    // MARK: - Interactive sheet callbacks

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
        guard let account else {
            finishInteractive(outcome: .failed("Internal error: no target account."))
            return
        }
        let result = await exchangeAndIngest(joined: joined, attempt: current, account: account)
        applyStepFromOutcome(result)
        finishInteractive(outcome: result)
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
        guard let account else {
            finishInteractive(outcome: .failed("Internal error: no target account."))
            return
        }
        let expectedState = current.state
        let verifier = current.verifier
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else {
            let out = ReloginOutcome.failed("Callback URL is missing query parameters.")
            applyStepFromOutcome(out)
            finishInteractive(outcome: out)
            return
        }
        let code = items.first { $0.name == "code" }?.value
        let receivedState = items.first { $0.name == "state" }?.value
        let errorParam = items.first { $0.name == "error" }?.value
        if let errorParam {
            let out = ReloginOutcome.failed("Anthropic rejected the authorization: \(errorParam).")
            applyStepFromOutcome(out)
            finishInteractive(outcome: out)
            return
        }
        guard let code, !code.isEmpty else {
            let out = ReloginOutcome.failed("Callback URL did not include an authorization code.")
            applyStepFromOutcome(out)
            finishInteractive(outcome: out)
            return
        }
        guard let receivedState, receivedState == expectedState else {
            let out = ReloginOutcome.failed("OAuth state mismatch — refusing to use this code.")
            applyStepFromOutcome(out)
            finishInteractive(outcome: out)
            return
        }
        step = .exchanging
        do {
            let payload = try await engine.exchangeCode(code: code, state: receivedState, verifier: verifier)
            let out = try await ingest(payload: payload, account: account)
            applyStepFromOutcome(out)
            finishInteractive(outcome: out)
        } catch {
            let out = ReloginOutcome.failed(error.localizedDescription)
            applyStepFromOutcome(out)
            finishInteractive(outcome: out)
        }
    }

    // MARK: - Shared exchange + ingest

    /// Splits the `code#state` string, validates the state, exchanges the code
    /// for tokens, then ingests. Returns the terminal outcome.
    private func exchangeAndIngest(
        joined: String,
        attempt: OAuthLoginEngine.Attempt,
        account: AccountDTO
    ) async -> ReloginOutcome {
        DiagnosticsLogger.shared.log(.info, subsystem: "relogin",
            "captured auth code len=\(joined.count) hasHash=\(joined.contains("#")) prefix=\(joined.prefix(8))…")
        let parts = joined.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return .failed("Auth code format unexpected (no `#` separator).")
        }
        let code = parts[0]
        let receivedState = parts[1]
        guard receivedState == attempt.state else {
            return .failed("OAuth state mismatch — refusing to use this code.")
        }
        do {
            let payload = try await engine.exchangeCode(
                code: code, state: receivedState, verifier: attempt.verifier)
            return try await ingest(payload: payload, account: account)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Calls `csw ingest-oauth` and maps the result to a `ReloginOutcome`.
    private func ingest(
        payload: OAuthLoginEngine.ExchangedToken,
        account: AccountDTO
    ) async throws -> ReloginOutcome {
        guard let store else {
            return .failed("Internal error: no store reference.")
        }

        // Identity guard: sourced from the exchange response (not a JWT lift —
        // Claude Code access tokens are opaque so emailFromJWT returns nil).
        // Mismatch is terminal: retrying would re-authorize the wrong account.
        if let signedIn = payload.signedInEmail,
           signedIn.lowercased() != account.email.lowercased() {
            return .identityMismatch(signedInAs: signedIn, expected: account.email)
        }

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
        // When the rewritten account was already active, the running `claude`
        // CLI is still holding the now-superseded tokens in memory. Trigger
        // the same post-swap pipeline a normal swap uses — claude-watch SIGINT
        // → `claude --resume <sid>` keeps the conversation; cmux panes get the
        // same treatment via CmuxPaneRelauncher; IDE windows reload if the
        // user has the toggle on. Inactive re-login skips this since no live
        // CLI is affected.
        if res.wroteLive {
            store.schedulePostSwapIntegrations()
        }
        return .succeeded(displayName: res.account.displayName, wroteLive: res.wroteLive)
    }

    // MARK: - Step/outcome helpers

    /// Maps a `ReloginOutcome` onto the `@Published step` for the interactive sheet UI.
    private func applyStepFromOutcome(_ outcome: ReloginOutcome) {
        switch outcome {
        case .succeeded(let name, let live):
            step = .done(displayName: name, wroteLive: live)
        case .failed(let msg):
            step = .failed(msg)
        case .needsManualSignIn:
            step = .failed("Session expired — please sign in manually.")
        case .identityMismatch(let signedIn, let expected):
            step = .identityMismatch(signedInAs: signedIn, expectedEmail: expected)
        }
    }

    /// Fires the completion handler exactly once for an interactive attempt.
    private func finishInteractive(outcome: ReloginOutcome) {
        let cb = completion
        completion = nil
        cb?(outcome)
    }

    /// Clears the single-flight guard. Called when an attempt fully completes
    /// (success, failure, or window close).
    private func clearFlight() {
        inFlight = false
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
