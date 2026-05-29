import Foundation

/// Shared JavaScript snippets for the Claude Code OAuth flow.
///
/// Centralised here so the interactive sheet's NSViewRepresentable Coordinator
/// and the headless `HeadlessOAuthWebDriver` reference the same strings —
/// a single edit fixes both paths.
///
/// All scripts are self-contained IIFEs returning a value or null so they are
/// safe to fire on any page without side-effects beyond the ones documented.
enum OAuthWebScripts {

    /// Searches every visible textual element for a base64url-ish
    /// `<code>#<state>` string. Conservative pattern — must be long enough to
    /// plausibly be a real auth code (>= 32 chars before the `#` and >= 16 chars
    /// after) so transient page strings containing `#` (anchor URLs, hashes in
    /// error messages) don't false-positive.
    ///
    /// Returns the matched `code#state` string, or null when not yet present.
    static let scanScript = """
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
    /// whose visible text is exactly "Authorize"/"Authorise" (deny/cancel words
    /// are excluded). Returns "clicked" once it fires, else null so the poller
    /// keeps trying until the consent button appears.
    static let authorizeScript = """
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

    /// Returns "signin" when the current page is unambiguously a claude.ai
    /// password-entry login form. The probe is intentionally conservative:
    ///
    ///   - Requires a visible `input[type=password]` AND a URL path that
    ///     contains "login" or ends at "/" or "/login".
    ///   - Returns null for every other page (org-picker, passkey prompt,
    ///     consent screen, usage pages) so callers treat those as
    ///     "still progressing" rather than "needs manual sign-in".
    ///
    /// This avoids the failure mode of inferring dead cookies from the
    /// ABSENCE of an Authorize button — interstitials (org picker, passkey)
    /// look form-like but resolve automatically once the user completes them.
    /// Only a confirmed password field is a reliable "session is gone" signal.
    static let signInProbeScript = """
    (function() {
      const hasPassword = !!document.querySelector('input[type="password"]');
      if (!hasPassword) return null;
      const path = location.pathname.toLowerCase();
      const isLoginPath = path.includes('login') || path === '/' || path === '';
      if (!isLoginPath) return null;
      return 'signin';
    })();
    """
}
