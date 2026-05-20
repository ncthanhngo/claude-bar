import Foundation
import Security
import SwiftUI

/// Manages iCloud Drive sync: passphrase storage, push/pull/status.
///
/// Passphrase is stored in the local (non-synced) macOS Keychain so the user
/// only needs to enter it once per machine.
@MainActor
final class CloudSyncCoordinator: ObservableObject {

    @Published private(set) var status: CswClient.CloudStatusDTO?
    @Published private(set) var isBusy = false
    @Published var lastError: String?
    @Published var showPassphraseSheet = false
    @Published var passphraseIntent: PassphraseIntent = .push

    enum PassphraseIntent { case push, pull, changePassphrase }

    private let client: CswClient
    private let keychainService = "claude-bar-cloudsync-passphrase"
    private let keychainAccount = "passphrase"

    init(client: CswClient) { self.client = client }

    // MARK: - Passphrase keychain

    var hasStoredPassphrase: Bool { loadPassphrase() != nil }

    func loadPassphrase() -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            // Never show an authentication prompt — return nil if UI would be required.
            // This prevents a blocking keychain dialog in the middle of a swap.
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip
        ]
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func savePassphrase(_ pass: String) {
        let data = pass.data(using: .utf8)!
        let del: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: keychainService,
                                     kSecAttrAccount: keychainAccount]
        SecItemDelete(del as CFDictionary)
        let add: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: keychainService,
                                     kSecAttrAccount: keychainAccount,
                                     kSecValueData: data]
        SecItemAdd(add as CFDictionary, nil)
    }

    func clearPassphrase() {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                    kSecAttrService: keychainService,
                                    kSecAttrAccount: keychainAccount]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - Actions

    func refreshStatus() async {
        guard let s = try? await client.cloudStatus() else { return }
        status = s
    }

    func push(passphrase: String) async {
        isBusy = true; lastError = nil
        defer { isBusy = false }
        do {
            try await client.cloudPush(passphrase: passphrase)
            savePassphrase(passphrase)
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pull(passphrase: String) async {
        isBusy = true; lastError = nil
        defer { isBusy = false }
        do {
            try await client.cloudPull(passphrase: passphrase)
            savePassphrase(passphrase)
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func forget() async {
        isBusy = true; lastError = nil
        defer { isBusy = false }
        do {
            try await client.cloudForget()
            clearPassphrase()
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Called on startup: if no local accounts exist but a cloud bundle does,
    /// prompt the user to restore.
    func checkOnboarding(snapshot: ListAccountsDTO?) async {
        guard let snap = snapshot, snap.accounts.isEmpty else { return }
        guard let s = try? await client.cloudStatus(), s.exists else { return }
        status = s
        passphraseIntent = .pull
        showPassphraseSheet = true
    }
}
