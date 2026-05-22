import AppKit
import SwiftUI

struct LocalMCPSettingsView: View {
    @EnvironmentObject var coordinator: LocalMCPCoordinator
    @EnvironmentObject var cloudSync: CloudSyncCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @State private var pendingDisconnect: PendingDisconnect?
    @State private var connectorPrompts: MCPConnectorPrompts = .empty
    @State private var expandedConnectorPrompt: String?  // "service-key" of expanded row

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
        .task {
            await coordinator.refresh()
            connectorPrompts = MCPConnectorPrompts.decode(from: settings.mcpConnectorPromptsJSON)
        }
        .sheet(item: $coordinator.connectSheet) { target in
            ConnectTokenSheet(target: target)
                .environmentObject(coordinator)
                .environmentObject(cloudSync)
        }
        .sheet(item: $coordinator.gdriveSheet) { target in
            ConnectGoogleSheet(target: target)
                .environmentObject(coordinator)
                .environmentObject(cloudSync)
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
                    await pushCloudIfConfigured()
                    pendingDisconnect = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDisconnect = nil }
        } message: { _ in
            Text("Removes the token from this Mac's Keychain and clears the connector from your registry. Shared connector removal affects every account that does not have its own connector.")
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
            Text("Slack, ClickUp, and Google Workspace tokens live in the macOS Keychain. Shared connectors work for every Claude Bar account on this Mac; account-specific connectors override shared ones. Tool results still flow through your Claude chat history, which may be shared if you share that Claude login.")
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
        SettingsGroup("Connectors", subtitle: "Connect once in Shared Connectors for every Claude Bar account on this Mac. Per-account rows can still override a shared connector.") {
            let shared = coordinator.accounts.first { $0.shared == true }
            let accountRows = coordinator.accounts.filter { $0.shared != true }
            if coordinator.accounts.isEmpty {
                Text(coordinator.isBusy ? "Loading…" : "No accounts yet — add one in the Accounts tab.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if let shared {
                        accountBlock(shared)
                        Divider()
                    }
                    ForEach(accountRows) { acc in
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
                if acc.shared == true {
                    Text("SHARED")
                        .font(.system(size: 9, weight: .bold)).tracking(0.4)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor).clipShape(Capsule())
                }
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
        .background(accountBlockBackground(acc))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func accountBlockBackground(_ acc: MCPAccountSummaryDTO) -> Color {
        if acc.shared == true { return Color.accentColor.opacity(0.07) }
        if acc.active { return Color.green.opacity(0.06) }
        return Color.secondary.opacity(0.04)
    }

    private func connectorRow(account: Int, connector: MCPConnectorSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
                promptDisclosureButton(account: account, service: connector.service)
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
            if expandedConnectorPrompt == promptKey(account: account, service: connector.service) {
                connectorPromptEditor(service: connector.service)
                    .padding(.leading, 26)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        }
    }

    private func promptKey(account: Int, service: String) -> String {
        "\(account):\(service)"
    }

    @ViewBuilder private func promptDisclosureButton(account: Int, service: String) -> some View {
        let key = promptKey(account: account, service: service)
        let isOpen = expandedConnectorPrompt == key
        let filled = !connectorPromptIsEmpty(service: service)
        Button {
            expandedConnectorPrompt = isOpen ? nil : key
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filled ? "text.badge.checkmark" : "square.and.pencil")
                    .font(.system(size: 10, weight: .semibold))
                Text(isOpen ? "Ẩn prompt" : (filled ? "Sửa prompt ✓" : "Sửa prompt"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(filled ? Color.green : Color.accentColor)
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .help("Markdown hướng dẫn Claude khi đọc dữ liệu từ connector này. Tự lưu khi gõ.")
    }

    /// True when this connector's prompt (or any of its Google sub-tags) is
    /// still blank — drives the "Sửa prompt" vs "Sửa prompt ✓" + colour
    /// swap on the disclosure pill.
    private func connectorPromptIsEmpty(service: String) -> Bool {
        switch service.lowercased() {
        case "slack":   return connectorPrompts.slack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "clickup": return connectorPrompts.clickup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "gdrive":
            return [connectorPrompts.gdrive, connectorPrompts.gmail,
                    connectorPrompts.gcal, connectorPrompts.gsheets]
                .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        default: return true
        }
    }

    /// For non-Google services: one TextEditor mapped to the matching Tag.
    /// For service=="gdrive" we surface 4 sub-tag editors (Drive / Gmail /
    /// Calendar / Sheets) since the Google OAuth scope covers all four.
    @ViewBuilder private func connectorPromptEditor(service: String) -> some View {
        switch service.lowercased() {
        case "slack":
            singleTagEditor(.slack, blurb: "Ví dụ: chỉ DMs, mention urgent, channel #engineering")
        case "clickup":
            singleTagEditor(.clickup, blurb: "Ví dụ: list 'Đang làm hôm nay' + tasks due trong 24h")
        case "gdrive":
            googleSubTagsEditor()
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func singleTagEditor(_ tag: MCPConnectorPrompts.Tag, blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(blurb).font(.caption).foregroundStyle(.tertiary)
            promptTextEditor(tag: tag, minHeight: 70)
        }
    }

    @ViewBuilder private func googleSubTagsEditor() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Google bao gồm nhiều surface — ghi hướng dẫn riêng cho từng phần. Claude sẽ đọc đúng block trước khi gọi tool tương ứng.")
                .font(.caption).foregroundStyle(.tertiary)
            ForEach([MCPConnectorPrompts.Tag.gdrive,
                     .gmail, .gcal, .gsheets]) { tag in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: tag.symbolName)
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                        Text(tag.displayName)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    promptTextEditor(tag: tag, minHeight: 56)
                }
            }
        }
    }

    @ViewBuilder private func promptTextEditor(tag: MCPConnectorPrompts.Tag, minHeight: CGFloat) -> some View {
        let binding = Binding<String>(
            get: { connectorPrompts.value(for: tag) },
            set: { newValue in
                connectorPrompts.set(tag, to: newValue)
                settings.mcpConnectorPromptsJSON = connectorPrompts.encodeToJSON()
                MCPConnectorPromptsWriter.write(connectorPrompts)
            }
        )
        TextEditor(text: binding)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: minHeight, maxHeight: 160)
            .padding(5)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
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
        if c.usesShared == true { return .accentColor }
        if c.hasSecret { return .secondary }
        return .secondary
    }

    private func pushCloudIfConfigured() async {
        guard let passphrase = cloudSync.loadPassphrase() else { return }
        await cloudSync.push(passphrase: passphrase)
    }
}

// MARK: - Sheets

private struct ConnectTokenSheet: View {
    let target: LocalMCPCoordinator.ConnectSheetTarget
    @EnvironmentObject var coordinator: LocalMCPCoordinator
    @EnvironmentObject var cloudSync: CloudSyncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var token: String = ""
    @State private var displayName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.accountNumber == 0 ? "Connect \(target.serviceLabel) for all accounts" : "Connect \(target.serviceLabel)")
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
                        let connected = await coordinator.connectToken(
                            account: target.accountNumber,
                            service: target.service,
                            token: t,
                            displayName: displayName.isEmpty ? nil : displayName
                        )
                        if connected {
                            await pushCloudIfConfigured()
                            dismiss()
                        }
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

    private func pushCloudIfConfigured() async {
        guard let passphrase = cloudSync.loadPassphrase() else { return }
        await cloudSync.push(passphrase: passphrase)
    }
}

private struct ConnectGoogleSheet: View {
    let target: LocalMCPCoordinator.GDriveSheetTarget
    @EnvironmentObject var coordinator: LocalMCPCoordinator
    @EnvironmentObject var cloudSync: CloudSyncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var clientID: String = ""
    @State private var clientSecret: String = ""
    @State private var displayName: String = ""
    @State private var importError: String?

    private var hasDefault: Bool {
        coordinator.installStatus?.hasDefaultGDriveClient == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.accountNumber == 0 ? "Connect Google for all accounts" : "Connect Google")
                .font(.headline)
            Text(hasDefault
                 ? "Clicking Connect opens your browser for Google consent. We request read-only Drive, Calendar, and Gmail scopes. OAuth tokens stay in your Keychain. Leave Client ID empty to use the app default, or import/paste your Desktop OAuth client JSON."
                 : "Paste your Google OAuth Desktop client ID and client secret, or import the downloaded JSON file. We request read-only Drive, Calendar, and Gmail scopes. Enable Drive, Calendar, and Gmail APIs in the same Google Cloud project.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                importGoogleOAuthJSON()
            } label: {
                Label("Import JSON", systemImage: "doc.badge.gearshape")
            }
            .buttonStyle(.bordered)
            TextField(hasDefault ? "Client ID override (optional)" : "Client ID (xxxx.apps.googleusercontent.com)", text: $clientID)
                .textFieldStyle(.roundedBorder)
            SecureField("Client secret (from the same Desktop OAuth client)", text: $clientSecret)
                .textFieldStyle(.roundedBorder)
            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Optional label", text: $displayName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open browser to connect") {
                    let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await coordinator.connectGoogle(
                            account: target.accountNumber,
                            clientID: cid,
                            clientSecret: secret,
                            displayName: displayName.isEmpty ? nil : displayName
                        )
                        await pushCloudIfConfigured()
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

    private func importGoogleOAuthJSON() {
        let panel = NSOpenPanel()
        panel.title = "Select Google OAuth client JSON"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            let originalLevel = window.level
            window.level = .normal
            panel.beginSheetModal(for: window) { response in
                window.level = originalLevel
                guard response == .OK, let url = panel.url else { return }
                importGoogleOAuthJSON(from: url)
            }
            return
        }
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importGoogleOAuthJSON(from: url)
    }

    private func importGoogleOAuthJSON(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let parsed = try JSONDecoder().decode(GoogleOAuthClientFile.self, from: data)
            let client = parsed.installed ?? parsed.web
            guard let client, !client.clientID.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            clientID = client.clientID
            clientSecret = client.clientSecret ?? ""
            if displayName.isEmpty {
                displayName = "Google"
            }
            importError = nil
        } catch {
            importError = "Could not read client_id/client_secret from this JSON. Create an OAuth Client ID with Application type Desktop app, then download its JSON."
        }
    }

    private func pushCloudIfConfigured() async {
        guard let passphrase = cloudSync.loadPassphrase() else { return }
        await cloudSync.push(passphrase: passphrase)
    }
}

private struct GoogleOAuthClientFile: Decodable {
    let installed: GoogleOAuthClient?
    let web: GoogleOAuthClient?
}

private struct GoogleOAuthClient: Decodable {
    let clientID: String
    let clientSecret: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}
