import Foundation
import AppKit

/// Headless variant of the Add-Account flow: runs `claude auth login` as a
/// background subprocess (no Terminal.app, no osascript) so the user only sees
/// their default browser open to the Anthropic OAuth page. Pairs with
/// `KeychainWatcher` — once `claude` finishes the OAuth dance and writes the
/// fresh OAuth blob to Keychain, the watcher fires and the wizard advances.
///
/// Compared to `TerminalLauncher`:
///  - No Terminal window pops up.
///  - URL opens in user's default browser (Chrome/Arc/Firefox/...) instead of
///    a Safari-backed WKWebView. Their browser already has cookies/2FA state,
///    so SSO + magic-link logins are smoother.
///
/// Compared to `LoginWindowController` (claude.ai web flow):
///  - Captures the **OAuth Bearer token** for Claude Code CLI, not the
///    claude.ai sessionKey cookie. Web polling requires the cookie path
///    (per-row "Connect web") which is unavoidable WKWebView.
enum BrowserOAuthLogin {

    enum LoginError: LocalizedError {
        case binaryNotFound
        case spawnFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Could not find the `claude` CLI. Install it via npm or Homebrew first."
            case .spawnFailed(let msg):
                return "Failed to launch claude auth login: \(msg)"
            }
        }
    }

    /// Holds the in-flight subprocess so its pipe handlers stay alive between
    /// callbacks. Cancelled and replaced on each new `start()` call.
    private static var activeProcess: Process?

    /// Spawn `claude auth login --claudeai` in the background. Returns once
    /// the process is launched (NOT once login completes — that's the
    /// KeychainWatcher's job). Throws if the binary can't be located or the
    /// subprocess refuses to launch.
    static func start() throws {
        guard let claudePath = ClaudeBinaryLocator.find() else {
            throw LoginError.binaryNotFound
        }
        cancel() // best-effort cleanup of any prior attempt

        // Logout first so claude actually re-runs the OAuth flow instead of
        // short-circuiting with "already logged in as …". Best-effort: if
        // logout errors out (no existing login, ACL prompt, etc.) we still
        // proceed to login.
        let logout = Process()
        logout.executableURL = URL(fileURLWithPath: claudePath)
        logout.arguments = ["auth", "logout"]
        logout.standardOutput = Pipe()
        logout.standardError = Pipe()
        try? logout.run()
        logout.waitUntilExit()

        let login = Process()
        login.executableURL = URL(fileURLWithPath: claudePath)
        login.arguments = ["auth", "login", "--claudeai"]

        let pipe = Pipe()
        login.standardOutput = pipe
        login.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            openAnthropicURLs(in: text)
        }

        // Drop the pipe handler when the process exits so we don't leak it.
        login.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try login.run()
        } catch {
            throw LoginError.spawnFailed(error.localizedDescription)
        }
        activeProcess = login
    }

    /// Kill the running login subprocess, if any. Used when the user cancels
    /// the wizard mid-flow.
    static func cancel() {
        if let p = activeProcess, p.isRunning {
            p.terminate()
        }
        activeProcess = nil
    }

    /// Scan a chunk of subprocess output for OAuth URLs and hand them to the
    /// default browser. `claude` usually opens the URL itself via macOS
    /// `open`, but when running fully headless it sometimes falls back to
    /// printing "Paste this in your browser: …" — this catches that case.
    private static func openAnthropicURLs(in text: String) {
        let pattern = #"https?://[^\s\"'<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let m = match,
                  let r = Range(m.range, in: text),
                  let url = URL(string: String(text[r])),
                  let host = url.host?.lowercased(),
                  host.contains("anthropic") || host.contains("claude.ai") else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
