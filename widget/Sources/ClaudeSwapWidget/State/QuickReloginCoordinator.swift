import AppKit
import CryptoKit
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
/// 5. Decode the access_token JWT to read the signed-in email and confirm it
///    matches the account the user right-clicked — refuses to overwrite
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

    // PKCE state lives for the duration of one re-login attempt.
    private var pkceVerifier: String?
    private var oauthState: String?
    private var dataStore: WKWebsiteDataStore?

    // OAuth client constants — must match the Claude Code CLI's registration
    // (same client_id the Go TokenRefresher already uses at
    // backend/internal/adapter/oauth/token_refresher.go).
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let authorizeURL = "https://claude.ai/oauth/authorize"
    private let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    private let scope = "org:create_api_key user:profile user:inference"

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
        self.pkceVerifier = Self.makeCodeVerifier()
        self.oauthState = Self.makeRandomState()
        guard let verifier = pkceVerifier, let state = oauthState else { return }
        guard let url = buildAuthorizeURL(verifier: verifier, state: state) else {
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
            guard let self else { return }
            self.pkceVerifier = nil
            self.oauthState = nil
        }
    }

    func dismiss() {
        window.close()
        pkceVerifier = nil
        oauthState = nil
    }

    /// Called when the embedded WebView's DOM scan finds the rendered
    /// "Authentication Code" page Anthropic's OAuth server shows after the
    /// user clicks Authorize. The code on that page is the `<code>#<state>`
    /// concatenation Claude Code CLI normally asks the user to paste into
    /// the terminal — we split it, validate the state, and drive the rest
    /// of the flow without making the user copy/paste.
    func handleManualAuthCode(_ joined: String) async {
        guard let expectedState = oauthState, let verifier = pkceVerifier else { return }
        // Consume PKCE pair atomically so a second DOM scan (page re-renders
        // its input, React hydration replays) cannot trigger a duplicate
        // exchange with the same code.
        pkceVerifier = nil
        oauthState = nil

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
            let payload = try await exchangeCode(code: code, state: receivedState, verifier: verifier)
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
        guard let expectedState = oauthState, let verifier = pkceVerifier else { return }
        // Consume the PKCE pair immediately so a second navigation to the
        // callback URL (back-button, redirect chain replay) cannot trigger
        // a second exchange with the same code — the token endpoint would
        // return 400 and the sheet would surface a `.failed` state for what
        // is actually a succeeded flow.
        pkceVerifier = nil
        oauthState = nil
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
            let payload = try await exchangeCode(code: code, state: receivedState, verifier: verifier)
            try await ingest(payload: payload)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    private func exchangeCode(code: String, state: String, verifier: String) async throws -> ExchangedToken {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-bar-relogin/0.1", forHTTPHeaderField: "User-Agent")
        // Claude Code's token endpoint requires the `state` value back in the
        // exchange body — it is the second half of the `code#state` string the
        // Authorization Code page renders. Omitting it yields a 400
        // "Invalid request format" even though the code + verifier are valid.
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "code_verifier": verifier,
            "client_id": clientID,
            "redirect_uri": redirectURI,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        DiagnosticsLogger.shared.log(.info, subsystem: "relogin",
            "exchange POST \(tokenURL.absoluteString) keys=\(body.keys.sorted().joined(separator: ",")) code=\(code.prefix(6))… state=\(state.prefix(6))… verifierLen=\(verifier.count)")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "QuickRelogin", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response."])
        }
        if http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            DiagnosticsLogger.shared.log(.warning, subsystem: "relogin",
                "exchange FAIL \(http.statusCode) — \(body.prefix(300))")
            throw NSError(domain: "QuickRelogin", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Token endpoint \(http.statusCode): \(body.prefix(180))"])
        }
        DiagnosticsLogger.shared.log(.info, subsystem: "relogin", "exchange OK \(http.statusCode)")
        struct Wire: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int64?
            let scope: String?
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard !wire.access_token.isEmpty, let rt = wire.refresh_token, !rt.isEmpty else {
            throw NSError(domain: "QuickRelogin", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Token endpoint returned no usable token pair."])
        }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let lifetimeSec = wire.expires_in ?? 3600
        let expiresAt = nowMillis + lifetimeSec * 1000
        let scopes: [String] = (wire.scope ?? scope)
            .split(separator: " ")
            .map(String.init)
        let signedInEmail = Self.emailFromJWT(wire.access_token)
        return ExchangedToken(
            accessToken: wire.access_token,
            refreshToken: rt,
            expiresAt: expiresAt,
            scopes: scopes,
            signedInEmail: signedInEmail
        )
    }

    private func ingest(payload: ExchangedToken) async throws {
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

    // MARK: - PKCE / URL helpers

    private func buildAuthorizeURL(verifier: String, state: String) -> URL? {
        var comps = URLComponents(string: authorizeURL)
        let challenge = Self.codeChallenge(for: verifier)
        comps?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return comps?.url
    }

    fileprivate func isCallback(_ url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return (comps.host?.lowercased() == "console.anthropic.com")
            && (comps.path == "/oauth/code/callback")
    }

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func makeRandomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var v = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        let pad = 4 - v.count % 4
        if pad < 4 { v += String(repeating: "=", count: pad) }
        return Data(base64Encoded: v)
    }

    /// Lifts the `email` claim out of an access_token shaped like a JWT.
    /// Returns nil when the token isn't a JWT or the claim is absent — the
    /// caller then skips the identity guard rather than rejecting on a
    /// false-negative.
    private static func emailFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let email = obj["email"] as? String { return email }
        if let email = obj["preferred_username"] as? String,
           email.contains("@") { return email }
        return nil
    }

    fileprivate struct ExchangedToken {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int64
        let scopes: [String]
        let signedInEmail: String?
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
