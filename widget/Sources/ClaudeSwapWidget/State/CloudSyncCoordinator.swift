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

    /// Backups fetched by `listBackups` for the restore-from-backup sheet.
    /// Cleared whenever a fresh fetch starts so the UI can show a spinner.
    @Published private(set) var backups: [CswClient.CloudBackupInfoDTO] = []

    enum PassphraseIntent { case push, pull, changePassphrase, restoreFromBackup }

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
        // ThisDeviceOnly prevents the passphrase from syncing to iCloud Keychain
        // and appearing on other devices signed into the same Apple ID.
        let add: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrService: keychainService,
                                     kSecAttrAccount: keychainAccount,
                                     kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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

    /// Loads the list of available bundle copies (current + ring-buffer
    /// backups) with the given passphrase so seq + pushed-at can be displayed
    /// for each. Result is published via `backups`.
    func listBackups(passphrase: String) async {
        isBusy = true; lastError = nil
        backups = []
        defer { isBusy = false }
        do {
            backups = try await client.cloudListBackups(passphrase: passphrase)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Restores accounts from a specific ring-buffer slot. The user is
    /// expected to have chosen the slot from `backups`. On success the cached
    /// listing is cleared so a subsequent open re-fetches fresh metadata.
    func restoreBackup(slot: Int, passphrase: String) async {
        isBusy = true; lastError = nil
        defer { isBusy = false }
        do {
            try await client.cloudRestoreBackup(slot: slot, passphrase: passphrase)
            savePassphrase(passphrase)
            backups = []
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Clears the cached backups listing. UI calls this on sheet dismiss so a
    /// reopened sheet refetches and reflects any state change from elsewhere.
    func clearBackups() {
        backups = []
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
