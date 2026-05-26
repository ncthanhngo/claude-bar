import Foundation
import SwiftUI

/// Drives the Local MCP settings tab: install/uninstall the claude-bar-mcp
/// entry in ~/.claude.json, list per-account connector state, and run
/// connect/disconnect flows via the csw backend.
///
/// All token-bearing strings move backend-only via stdin or OAuth loopback;
/// nothing token-shaped touches @Published state.
@MainActor
final class LocalMCPCoordinator: ObservableObject {

    @Published private(set) var installStatus: MCPInstallStatusDTO?
    @Published private(set) var accounts: [MCPAccountSummaryDTO] = []
    /// Per-service tool catalog + enabled state. Populated lazily when
    /// the user expands a connector's disclosure in Settings → MCP, so
    /// the popover open path doesn't pay the round-trip for tools nobody
    /// is looking at.
    @Published private(set) var toolsByService: [String: [MCPToolSummaryDTO]] = [:]
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    /// Sheet state for paste-token flow (Slack, ClickUp).
    @Published var connectSheet: ConnectSheetTarget?
    /// Sheet state for Google Drive OAuth client-id prompt.
    @Published var gdriveSheet: GDriveSheetTarget?
    /// Sheet state for GitLab self-host instance add (name + base URL + PAT).
    /// GitLab is multi-instance so the flow doesn't fit the single-token sheet.
    @Published var gitlabSheet: GitLabSheetTarget?

    struct ConnectSheetTarget: Identifiable {
        let id = UUID()
        let accountNumber: Int
        let service: String
        let serviceLabel: String
    }

    struct GDriveSheetTarget: Identifiable {
        let id = UUID()
        let accountNumber: Int
    }

    struct GitLabSheetTarget: Identifiable {
        let id = UUID()
    }

    let client: CswClient
    init(client: CswClient) { self.client = client }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            installStatus = try await client.mcpStatus()
            accounts = try await client.mcpConnectorsList()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func install() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await client.mcpInstall()
            installStatus = try await client.mcpStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uninstall() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await client.mcpUninstall()
            installStatus = try await client.mcpStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reinstallForce() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await client.mcpInstall(force: true)
            installStatus = try await client.mcpStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func connectToken(account: Int, service: String, token: String, displayName: String?) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await client.mcpConnectorConnectToken(
                account: account, service: service, token: token, displayName: displayName
            )
            accounts = try await client.mcpConnectorsList()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func connectGoogle(account: Int, clientID: String, clientSecret: String, displayName: String?) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await client.mcpConnectorConnectGoogle(
                account: account, clientID: clientID, clientSecret: clientSecret, displayName: displayName
            )
            accounts = try await client.mcpConnectorsList()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setEnabled(account: Int, service: String, enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await client.mcpConnectorSetEnabled(account: account, service: service, enabled: enabled)
            accounts = try await client.mcpConnectorsList()
            // BuildServer() reads Enabled flags on each spawn, so a toggle
            // only takes effect on the next Claude Code session. SIGINT
            // running `claude` processes so claude-watch restarts them with
            // the new toolset — same machinery the swap flow uses, minus
            // the credential switch. cmux panes are skipped because the
            // cmux relauncher would race the resume; user keeps cmux state.
            await restartClaudeForMCPReload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Loads (or refreshes) the per-tool catalog for one service.
    /// Caches in `toolsByService[service]` so successive disclosures
    /// render instantly from the @Published copy without another
    /// round-trip. Toggling a tool calls `setToolEnabled` which
    /// invalidates this cache.
    func loadTools(service: String) async {
        do {
            let list = try await client.mcpToolsList(service: service)
            toolsByService[service] = list
        } catch {
            lastError = "Load tools (\(service)): \(error.localizedDescription)"
        }
    }

    /// Flip one tool on or off. Mirrors `setEnabled(account:service:)`
    /// for whole connectors — the same SIGINT-restart machinery applies
    /// so Claude Code's `tools/list` reissues with the new shape on the
    /// next prompt.
    func setToolEnabled(toolID: String, enabled: Bool, service: String) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await client.mcpToolsSetEnabled(toolID: toolID, enabled: enabled)
            await loadTools(service: service)
            await restartClaudeForMCPReload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func restartClaudeForMCPReload() async {
        let killed = CLISessionKiller.killAll(skipCmuxTracked: true)
        guard !killed.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        CLISessionKiller.forceKillSurvivors(killed)
    }

    func disconnect(account: Int, service: String) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await client.mcpConnectorDisconnect(account: account, service: service)
            accounts = try await client.mcpConnectorsList()
            await restartClaudeForMCPReload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Attempt to re-enable a soft-disconnected connector using the
    /// saved Keychain credential. Returns `true` when the credential
    /// verified and Enabled flipped back to true — the UI then stays
    /// on the connector row. Returns `false` when the saved credential
    /// is missing or rejected; the caller is expected to fall through
    /// to the existing connect-sheet flow so the user can paste fresh
    /// credentials.
    func reconnect(account: Int, service: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            let outcome = try await client.mcpConnectorReconnect(account: account, service: service)
            accounts = try await client.mcpConnectorsList()
            switch outcome {
            case .reEnabled:
                await restartClaudeForMCPReload()
                return true
            case .needsFreshCredential:
                return false
            }
        } catch {
            // Treat any other error (no saved credential, IO) as "needs
            // fresh" so the UI proceeds to the connect sheet rather
            // than dead-ending on an opaque error toast.
            return false
        }
    }
}
