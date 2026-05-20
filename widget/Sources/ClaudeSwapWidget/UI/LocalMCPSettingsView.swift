import SwiftUI

struct LocalMCPSettingsView: View {
    @EnvironmentObject var coordinator: LocalMCPCoordinator
    @State private var pendingDisconnect: PendingDisconnect?

    private struct PendingDisconnect: Identifiable {
        let id = UUID()
        let accountNumber: Int
        let service: String
        let serviceLabel: String
    }

    var body: some View {
        SettingsPage {
            privacyNotice
            gatewaySection
            connectorsSection
        }
        .task { await coordinator.refresh() }
        .sheet(item: $coordinator.connectSheet) { target in
            ConnectTokenSheet(target: target)
                .environmentObject(coordinator)
        }
        .sheet(item: $coordinator.gdriveSheet) { target in
            ConnectGoogleSheet(target: target)
                .environmentObject(coordinator)
        }
        .confirmationDialog(
            "Disconnect \(pendingDisconnect?.serviceLabel ?? "")?",
            isPresented: Binding(
                get: { pendingDisconnect != nil },
                set: { if !$0 { pendingDisconnect = nil } }
            ),
            presenting: pendingDisconnect
        ) { p in
            Button("Disconnect", role: .destructive) {
                Task {
                    await coordinator.disconnect(account: p.accountNumber, service: p.service)
                    pendingDisconnect = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDisconnect = nil }
        } message: { _ in
            Text("Removes the token from this Mac's Keychain and clears the connector from your registry. No way to undo from here.")
        }
        .overlay(alignment: .bottom) {
            if let msg = coordinator.lastError {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 10)
                    .onTapGesture { coordinator.lastError = nil }
            }
        }
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Local connectors stay on this Mac", systemImage: "lock.shield")
                .font(.subheadline.weight(.medium))
            Text("Slack, ClickUp, and Google Drive tokens live in the macOS Keychain, tied to your active Claude Bar account. Tool results still flow through your Claude chat history, which may be shared if you share that Claude login. Switching Claude Bar accounts switches which tokens the local gateway uses.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var gatewaySection: some View {
        SettingsGroup("Gateway", subtitle: "Wires the claude-bar-mcp entry into ~/.claude.json so Claude Code can call local connector tools.") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: gatewayIcon)
                    .foregroundColor(gatewayColor)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(gatewayTitle).font(.system(size: 13, weight: .medium))
                    if let cmd = coordinator.installStatus?.command {
                        Text(cmd).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("Not wired into Claude Code yet.").font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                gatewayButtons
            }
        }
    }

    private var gatewayIcon: String {
        guard let st = coordinator.installStatus else { return "questionmark.circle" }
        if st.conflict == true { return "exclamationmark.triangle.fill" }
        return st.installed ? "checkmark.seal.fill" : "circle.dashed"
    }

    private var gatewayColor: Color {
        guard let st = coordinator.installStatus else { return .secondary }
        if st.conflict == true { return .orange }
        return st.installed ? .green : .secondary
    }

    private var gatewayTitle: String {
        guard let st = coordinator.installStatus else { return "Checking…" }
        if st.conflict == true { return "Conflict — another command is registered" }
        return st.installed ? "Installed" : "Not installed"
    }

    @ViewBuilder
    private var gatewayButtons: some View {
        if coordinator.installStatus?.installed == true {
            Button("Uninstall") { Task { await coordinator.uninstall() } }
                .buttonStyle(.bordered)
            if coordinator.installStatus?.conflict == true {
                Button("Reinstall (force)") { Task { await coordinator.reinstallForce() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if coordinator.installStatus?.conflict == true {
            Button("Install (force overwrite)") { Task { await coordinator.reinstallForce() } }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Install") { Task { await coordinator.install() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var connectorsSection: some View {
        SettingsGroup("Connectors", subtitle: "Each row is one Claude Bar account. Connecting Slack/ClickUp/Drive on account A does not give account B access.") {
            if coordinator.accounts.isEmpty {
                Text(coordinator.isBusy ? "Loading…" : "No accounts yet — add one in the Accounts tab.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(coordinator.accounts) { acc in
                        accountBlock(acc)
                    }
                }
            }
        }
    }

    private func accountBlock(_ acc: MCPAccountSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(acc.displayName).font(.system(size: 13, weight: .medium))
                if acc.active {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold)).tracking(0.4)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green).clipShape(Capsule())
                }
                Spacer()
            }
            ForEach(acc.connectors) { c in
                connectorRow(account: acc.accountNumber, connector: c)
            }
        }
        .padding(8)
        .background(acc.active ? Color.green.opacity(0.06) : Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func connectorRow(account: Int, connector: MCPConnectorSummaryDTO) -> some View {
        HStack(spacing: 8) {
            Image(systemName: connector.systemImageName)
                .frame(width: 18)
                .foregroundColor(connector.enabled && connector.hasSecret ? .accentColor : .secondary)
            Text(connector.labelTitle).font(.system(size: 12))
            Text("·").foregroundColor(.secondary)
            Text(connector.state)
                .font(.caption)
                .foregroundColor(stateColor(for: connector))
            Spacer()
            if connector.enabled && connector.hasSecret {
                Button("Disconnect") {
                    pendingDisconnect = .init(
                        accountNumber: account,
                        service: connector.service,
                        serviceLabel: connector.labelTitle
                    )
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .font(.caption)
            } else {
                Button("Connect") {
                    presentConnect(account: account, service: connector.service, label: connector.labelTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func presentConnect(account: Int, service: String, label: String) {
        if service == "gdrive" {
            coordinator.gdriveSheet = .init(accountNumber: account)
        } else {
            coordinator.connectSheet = .init(accountNumber: account, service: service, serviceLabel: label)
        }
    }

    private func stateColor(for c: MCPConnectorSummaryDTO) -> Color {
        if c.needsReauth { return .orange }
        if c.enabled && c.hasSecret { return .green }
        if c.hasSecret { return .secondary }
        return .secondary
    }
}

// MARK: - Sheets

private struct ConnectTokenSheet: View {
    let target: LocalMCPCoordinator.ConnectSheetTarget
    @EnvironmentObject var coordinator: LocalMCPCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var token: String = ""
    @State private var displayName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(target.serviceLabel)")
                .font(.headline)
            Text(hint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Paste token", text: $token)
                .textFieldStyle(.roundedBorder)
            TextField("Optional label (e.g. workspace name)", text: $displayName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") {
                    let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await coordinator.connectToken(
                            account: target.accountNumber,
                            service: target.service,
                            token: t,
                            displayName: displayName.isEmpty ? nil : displayName
                        )
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var hint: String {
        switch target.service {
        case "slack":
            return "Slack user token (xoxp-… / xoxe-…). Required scopes: channels:history, channels:read, groups:history, groups:read, im:history, mpim:history, search:read. The token never appears in argv — it is piped to csw over stdin."
        case "clickup":
            return "ClickUp personal API token (starts with pk_). Settings → Apps → Generate. Token has account-wide scope; this MVP only invokes read endpoints."
        default:
            return "Paste the provider token."
        }
    }
}

private struct ConnectGoogleSheet: View {
    let target: LocalMCPCoordinator.GDriveSheetTarget
    @EnvironmentObject var coordinator: LocalMCPCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var clientID: String = ""
    @State private var displayName: String = ""

    private var hasDefault: Bool {
        coordinator.installStatus?.hasDefaultGDriveClient == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Google Drive")
                .font(.headline)
            Text(hasDefault
                 ? "Clicking Connect opens your browser for Google consent. We never see or store your Google password; only the refresh token comes back, and it stays in your Keychain. PKCE (S256) keeps the flow safe without a client secret."
                 : "Paste your Google OAuth Desktop client ID. Clicking Connect opens your browser for consent. We never see or store your Google password; only the refresh token comes back, and it stays in your Keychain. PKCE (S256) is used so no client secret is needed.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !hasDefault {
                TextField("Client ID (xxxx.apps.googleusercontent.com)", text: $clientID)
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Optional label", text: $displayName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open browser to connect") {
                    let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await coordinator.connectGoogle(
                            account: target.accountNumber,
                            clientID: cid,
                            displayName: displayName.isEmpty ? nil : displayName
                        )
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasDefault && clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
