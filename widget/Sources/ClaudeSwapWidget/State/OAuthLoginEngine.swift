import CryptoKit
import Foundation

/// Stateless primitives for the Claude Code CLI OAuth flow, shared by
/// interactive re-login, headless credential recovery, and (later) add-account.
///
/// Holds NO per-attempt state: each login attempt generates its own
/// `Attempt` (PKCE verifier + `state`) so two concurrent flows can never
/// clobber each other's PKCE pair. The coordinator owns the WebView/UI; this
/// type owns only the authorize-URL build and the token exchange.
///
/// Identity (email + org) is read from the token-exchange RESPONSE, not the
/// access token: Claude Code's access token is opaque (not a JWT), so a
/// JWT-claim lift returns nothing. The exchange response carries `account`
/// and `organization` objects which are the authoritative identity source.
struct OAuthLoginEngine {
    // OAuth client constants — must match the Claude Code CLI's registration
    // (same client_id the Go TokenRefresher uses at
    // backend/internal/adapter/oauth/token_refresher.go).
    let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    let authorizeURL = "https://claude.ai/oauth/authorize"
    let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    let scope = "org:create_api_key user:profile user:inference"

    /// One login attempt's PKCE pair + anti-CSRF `state`, generated fresh so
    /// each flow is self-contained. The authorize page renders `<code>#<state>`
    /// and the token endpoint requires the same `state` echoed back.
    struct Attempt {
        let verifier: String
        let state: String

        init() {
            verifier = OAuthLoginEngine.makeCodeVerifier()
            state = OAuthLoginEngine.makeRandomState()
        }
    }

    /// Result of a successful code-for-token exchange. `signedInEmail` /
    /// `organizationUuid` come from the response's `account`/`organization`
    /// objects and may be nil if Anthropic omits them.
    struct ExchangedToken {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int64
        let scopes: [String]
        let signedInEmail: String?
        let organizationUuid: String?
    }

    // MARK: - Authorize URL

    func buildAuthorizeURL(_ attempt: Attempt) -> URL? {
        var comps = URLComponents(string: authorizeURL)
        let challenge = Self.codeChallenge(for: attempt.verifier)
        comps?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: attempt.state),
        ]
        return comps?.url
    }

    func isCallback(_ url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return (comps.host?.lowercased() == "console.anthropic.com")
            && (comps.path == "/oauth/code/callback")
    }

    // MARK: - Token exchange

    /// Exchanges an authorization `code` (+ its `state`) for tokens. The
    /// `state` MUST be sent in the body — Claude Code's endpoint returns
    /// 400 "Invalid request format" without it (it is the second half of the
    /// `code#state` string the authorize page renders).
    func exchangeCode(code: String, state: String, verifier: String) async throws -> ExchangedToken {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-bar-relogin/0.1", forHTTPHeaderField: "User-Agent")
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
            throw NSError(domain: "OAuthLoginEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response."])
        }
        if http.statusCode >= 400 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            DiagnosticsLogger.shared.log(.warning, subsystem: "relogin",
                "exchange FAIL \(http.statusCode) — \(bodyStr.prefix(300))")
            throw NSError(domain: "OAuthLoginEngine", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Token endpoint \(http.statusCode): \(bodyStr.prefix(180))"])
        }
        DiagnosticsLogger.shared.log(.info, subsystem: "relogin", "exchange OK \(http.statusCode)")

        // Identity comes from `account`/`organization` here — the access_token
        // is opaque, so a JWT lift would yield nothing.
        struct Wire: Decodable {
            struct Account: Decodable { let email_address: String? }
            struct Organization: Decodable { let uuid: String? }
            let access_token: String
            let refresh_token: String?
            let expires_in: Int64?
            let scope: String?
            let account: Account?
            let organization: Organization?
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard !wire.access_token.isEmpty, let rt = wire.refresh_token, !rt.isEmpty else {
            throw NSError(domain: "OAuthLoginEngine", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Token endpoint returned no usable token pair."])
        }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let lifetimeSec = wire.expires_in ?? 3600
        let expiresAt = nowMillis + lifetimeSec * 1000
        let scopes: [String] = (wire.scope ?? scope)
            .split(separator: " ")
            .map(String.init)
        return ExchangedToken(
            accessToken: wire.access_token,
            refreshToken: rt,
            expiresAt: expiresAt,
            scopes: scopes,
            signedInEmail: wire.account?.email_address,
            organizationUuid: wire.organization?.uuid
        )
    }

    // MARK: - PKCE helpers

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
}
