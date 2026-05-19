import SwiftUI
import AppKit

/// Add a Claude account using only a magic-link URL (no email/password access).
///
/// Targets the Teams-workspace flow where admins distribute magic links
/// directly to team members. The orchestrator handles the WebKit cookie
/// dance + claude CLI subprocess; this sheet drives UI + saves the account
/// once `KeychainWatcher` confirms tokens landed.
struct MagicLinkLoginSheet: View {
    @ObservedObject var store: UsageStore
    @Binding var isPresented: Bool

    @StateObject private var login = MagicLinkLogin()
    @State private var watcher = KeychainWatcher()
    @State private var urlText: String = ""
    @State private var label: String = ""
    @State private var step: Step = .input
    @State private var error: String?

    enum Step: Equatable {
        case input
        case running
        case detected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .onDisappear {
            watcher.stop()
            login.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "link.circle.fill").foregroundStyle(.blue)
            Text("Login with magic link").font(.headline)
            Spacer()
            Text(stepLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stepLabel: String {
        switch step {
        case .input:    return "Step 1 of 2"
        case .running:  return "Step 1 of 2"
        case .detected: return "Step 2 of 2"
        }
    }

    // MARK: - Content per step

    @ViewBuilder
    private var content: some View {
        switch step {
        case .input:    inputView
        case .running:  runningView
        case .detected: detectedView
        }
    }

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste your Claude Teams magic link").font(.subheadline).bold()
            Text("The widget will use it to set a cookie, then drive the `claude` CLI through OAuth automatically. No browser interaction needed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://claude.ai/magic-link#…", text: $urlText, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .padding(.top, 4)
            Text("`claude logout` will run first, replacing any active CLI login. Make sure you've snapshotted it via **Add** if you want to keep it.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(statusTitle).font(.subheadline).bold()
            }
            Text(statusDetail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let email = login.detectedEmail {
                Text("Account: \(email)").font(.caption2).foregroundStyle(.secondary)
            }
            if !login.debugTail.isEmpty {
                ScrollView {
                    Text(login.debugTail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.06)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.08)))
        .onChange(of: login.status) { new in
            if case .failed(let msg) = new {
                error = msg
                step = .input  // back to input so user can retry
            }
        }
    }

    private var detectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Login complete").font(.subheadline).bold()
            }
            if let email = login.detectedEmail {
                Text(email).font(.caption).foregroundStyle(.secondary)
            }
            Text("Give this account a label so you can recognize it in the list.")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("e.g. work-teams, client-X", text: $label)
                .textFieldStyle(.roundedBorder)
                .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.08)))
    }

    // MARK: - Status text from orchestrator

    private var statusTitle: String {
        switch login.status {
        case .idle:                return "Starting…"
        case .loadingMagicLink:    return "Activating magic link…"
        case .spawningCli:         return "Logging out current CLI session…"
        case .waitingForOAuthURL:  return "Starting claude CLI…"
        case .completingOAuth:     return "Completing OAuth…"
        case .waitingForCallback:  return "Waiting for CLI callback…"
        case .success:             return "Done"
        case .failed(let msg):     return "Failed: \(msg)"
        }
    }

    private var statusDetail: String {
        switch login.status {
        case .loadingMagicLink:   return "Loading link in a hidden WebView so claude.ai sets the sessionKey cookie."
        case .spawningCli:        return "Clearing existing OAuth tokens from Keychain."
        case .waitingForOAuthURL: return "Parsing CLI output to grab the OAuth URL with its PKCE challenge."
        case .completingOAuth:    return "Cookie authorizes the request; backend redirects to localhost."
        case .waitingForCallback: return "claude CLI is receiving the auth code and exchanging it for OAuth tokens."
        default:                  return ""
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            Button("Cancel") { cancel() }
            Spacer()
            switch step {
            case .input:
                Button("Login") { startLogin() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValidMagicLink(urlText))
            case .running:
                EmptyView()
            case .detected:
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Flow

    private func isValidMagicLink(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.host == "claude.ai",
              url.path.contains("magic-link") else { return false }
        return url.fragment?.contains(":") == true
    }

    private func startLogin() {
        error = nil
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }

        step = .running
        // Start watcher in parallel — once claude writes tokens, advance UI.
        watcher.start { _ in
            login.markSuccess()
            label = login.detectedEmail ?? ""
            step = .detected
        }
        Task { await login.start(magicLinkURL: url) }
    }

    private func save() {
        if let existing = store.findDuplicateForMagicLink(email: login.detectedEmail) {
            let alert = NSAlert()
            alert.messageText = "This account is already saved"
            let emailHint = login.detectedEmail.map { " (email \($0))" } ?? ""
            alert.informativeText = "These credentials\(emailHint) match the row \"\(existing.displayName)\". Saving will create a second snapshot of the same identity.\n\nIf you actually intend a fresh entry, click Save anyway. Otherwise cancel and edit the existing row."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try store.addCurrentClaudeCodeAccount(
                label: label,
                sessionKey: login.capturedSessionKey,
                orgId: login.capturedOrgId,
                email: login.detectedEmail
            )
            isPresented = false
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }

    private func cancel() {
        watcher.stop()
        login.cancel()
        isPresented = false
    }
}
