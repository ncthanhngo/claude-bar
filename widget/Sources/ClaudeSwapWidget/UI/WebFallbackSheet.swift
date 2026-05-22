import SwiftUI
import WebKit

/// Floating-window content for the claude.ai web usage session.
///
/// Layout: address row + WebView + status footer.
/// User logs in once, and cookies persist for this account profile.
struct WebFallbackSheet: View {
    @EnvironmentObject var coordinator: WebFallbackCoordinator
    let accountView: AccountViewDTO
    let dataStore: WKWebsiteDataStore

    @State private var currentURL: URL? = URL(string: "https://claude.ai/")
    @State private var isLoading = false
    @State private var pageTitle = ""
    @State private var scrapeResult: String?

    private let homeURL = URL(string: "https://claude.ai/settings/usage")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            addressRow
            Divider()
            ClaudeWebView(
                initialURL: homeURL,
                dataStore: dataStore,
                currentURL: $currentURL,
                isLoading: $isLoading,
                title: $pageTitle,
                onCookiesChanged: {
                    Task { await coordinator.refreshConnectionState(for: accountView.account, dataStore: dataStore) }
                }
            )
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
    }

    private var addressRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundColor(.green).font(.system(size: 10))
            Text(currentURL?.absoluteString ?? "")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(accountView.account.displayName)
                    .font(.system(size: 11, weight: .medium))
                Text(accountView.account.email)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            connectionBadge
            Spacer()
            if let txt = scrapeResult {
                Text(txt)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(txt)
            }
            Button("Refresh web usage") {
                Task { await refreshUsage() }
            }
            .controlSize(.small)
            Button("Disconnect", role: .destructive) {
                Task {
                    await coordinator.disconnect(accountView.account)
                    scrapeResult = nil
                }
            }
            .controlSize(.small)
            .disabled(!coordinator.isLinked(accountView.account))
            Button("Close") { coordinator.dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: isUsableState
                  ? "checkmark.shield.fill"
                  : "lock.slash.fill")
                .foregroundColor(isUsableState ? .green : .orange)
                .font(.system(size: 11))
            Text(stateLabel)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func refreshUsage() async {
        if let usage = await coordinator.refreshWebUsage(for: accountView) {
            let fiveHour = usage.fiveHour.map { "5h \($0.percentInt)%" } ?? "5h unavailable"
            let sevenDay = usage.sevenDay.map { "7d \($0.percentInt)%" } ?? "7d unavailable"
            scrapeResult = "\(fiveHour), \(sevenDay)"
        } else {
            scrapeResult = coordinator.state(for: accountView.account).detail ?? "No web usage found on this page"
        }
    }

    private var isUsableState: Bool {
        if case .connected = coordinator.state(for: accountView.account) { return true }
        if case .linked = coordinator.state(for: accountView.account) { return true }
        return false
    }

    private var stateLabel: String {
        switch coordinator.state(for: accountView.account) {
        case .connected: return "Connected"
        case .linked: return "Web profile linked"
        case .notLinked: return "Not linked"
        case .fallback: return "Sign in required"
        }
    }
}
