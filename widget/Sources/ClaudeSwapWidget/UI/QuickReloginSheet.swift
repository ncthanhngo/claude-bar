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
            return "Sign in to Anthropic and click Authorize."
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
        ClaudeWebView(
            initialURL: initialURL,
            dataStore: dataStore,
            currentURL: $currentURL,
            isLoading: $isLoading,
            title: $pageTitle,
            onCookiesChanged: {}
        )
        .overlay(alignment: .topTrailing) {
            navigationInterceptor
        }
    }

    /// Empty overlay whose `task(id:)` watches `currentURL` and forwards any
    /// console.anthropic.com/oauth/code/callback navigation to the coordinator
    /// for token exchange. Decoupled from `ClaudeWebView`'s navigation delegate
    /// so we don't have to fork that shared component just to add a redirect
    /// hook.
    private var navigationInterceptor: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: currentURL?.absoluteString ?? "") {
                guard let url = currentURL else { return }
                if isCallback(url) {
                    await coordinator.handleRedirect(url)
                } else if case .loading = coordinator.step,
                          url.host?.contains("claude.ai") == true {
                    // First navigation completed — switch banner to the
                    // "user is interacting" state. We don't transition out of
                    // .loading on every URL change since the OAuth provider
                    // may bounce through multiple intermediate pages.
                    Task { @MainActor in
                        coordinator.step = .awaitingConsent
                    }
                }
            }
    }

    private func isCallback(_ url: URL) -> Bool {
        url.host?.lowercased() == "console.anthropic.com"
            && url.path == "/oauth/code/callback"
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
