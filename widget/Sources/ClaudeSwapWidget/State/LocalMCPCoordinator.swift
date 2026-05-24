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
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    /// Sheet state for paste-token flow (Slack, ClickUp).
    @Published var connectSheet: ConnectSheetTarget?
    /// Sheet state for Google Drive OAuth client-id prompt.
    @Published var gdriveSheet: GDriveSheetTarget?

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

    private let client: CswClient
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

    func disconnect(account: Int, service: String) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await client.mcpConnectorDisconnect(account: account, service: service)
            accounts = try await client.mcpConnectorsList()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
