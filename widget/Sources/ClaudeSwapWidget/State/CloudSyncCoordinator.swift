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

    /// Rows fetched by `preview` for the restore-preview table. Cleared on
    /// sheet dismiss + before each fresh fetch.
    @Published private(set) var previewRows: [CswClient.CloudPreviewRowDTO] = []

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

    /// Background-friendly pull: same as `pull` but swallows errors silently.
    /// Used by the auto-sync loop where transient failures (anti-rollback,
    /// missing bundle, wrong passphrase after a rotation) must not surface in
    /// the diagnostics UI — manual Push/Restore still surfaces them.
    func pullQuiet(passphrase: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.cloudPull(passphrase: passphrase)
            await refreshStatus()
        } catch {
            // Silent on purpose.
        }
    }

    /// Background-friendly push: same as `push` but swallows errors silently.
    /// Used by the auto-sync loop so a transient push failure (e.g. iCloud
    /// hasn't mounted yet) doesn't show as a red error in Diagnostics.
    func pushQuiet(passphrase: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.cloudPush(passphrase: passphrase)
            await refreshStatus()
        } catch {
            // Silent on purpose.
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

    /// Loads the side-by-side preview rows (local vs bundle) for `slot`.
    /// Result published via `previewRows`. Read-only — never mutates keychain.
    func preview(slot: Int, passphrase: String) async {
        isBusy = true; lastError = nil
        previewRows = []
        defer { isBusy = false }
        do {
            previewRows = try await client.cloudPreview(slot: slot, passphrase: passphrase)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Applies the bundle entries whose identity is in `identities` only.
    /// Wraps `cloudPullSelective` + saves passphrase + refreshes status.
    /// Caller must `store.refreshNow()` afterwards so the menu picks up new rows.
    func pullSelective(slot: Int, passphrase: String, identities: [String]) async {
        isBusy = true; lastError = nil
        defer { isBusy = false }
        do {
            try await client.cloudPullSelective(slot: slot, passphrase: passphrase, identities: identities)
            savePassphrase(passphrase)
            previewRows = []
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearPreview() {
        previewRows = []
    }

    /// Encrypts the local bundle to `destPath` for cross-Apple-ID sharing.
    /// No sync-state mutation, no ring-buffer rotation — purely an out-of-band
    /// snapshot for the recipient to import.
    func exportBundle(passphrase: String, destPath: String) async {
        isBusy = true; lastError = nil
        defer { isBusy = false }
        do {
            try await client.cloudExport(passphrase: passphrase, destPath: destPath)
            savePassphrase(passphrase)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Loads preview rows for an externally-supplied bundle file. Mirrors
    /// `preview(slot:)` but reads `srcPath` instead. Result published via
    /// `previewRows` so the same RestorePreviewSheet UI can render either path.
    func importPreview(passphrase: String, srcPath: String) async {
        isBusy = true; lastError = nil
        previewRows = []
        defer { isBusy = false }
        do {
            previewRows = try await client.cloudImportPreview(passphrase: passphrase, srcPath: srcPath)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Applies selected accounts from an externally-supplied bundle file.
    /// Bypasses anti-rollback and leaves the iCloud sync chain untouched.
    /// Caller must `store.refreshNow()` afterwards so the menu picks up new rows.
    func importSelective(passphrase: String, srcPath: String, identities: [String]) async {
        isBusy = true; lastError = nil
        defer { isBusy = false }
        do {
            try await client.cloudImportSelective(passphrase: passphrase, srcPath: srcPath, identities: identities)
            previewRows = []
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
