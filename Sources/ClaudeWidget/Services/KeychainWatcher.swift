import Foundation

/// Polls Claude Code's Keychain entry every 2s and fires when the blob changes
/// vs. the baseline captured at `start()`. Used by the "Add account" wizard
/// to detect when a fresh `claude` CLI login lands in the Keychain.
@MainActor
final class KeychainWatcher {

    private var timer: Timer?
    private var baseline: String?
    private var onChange: ((String) -> Void)?

    /// Captures the current Keychain blob (or nil if absent) as the baseline,
    /// then polls every 2s. Calls `onChange` with the new blob the first time
    /// the value differs from baseline, then stops automatically.
    func start(onChange: @escaping (String) -> Void) {
        stop()
        baseline = try? ClaudeCodeCredentials.read()
        self.onChange = onChange
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        baseline = nil
        onChange = nil
    }

    private func tick() {
        let current = try? ClaudeCodeCredentials.read()
        // Treat "no creds → some creds" and "blob A → blob B" both as a change.
        // No-op while still matching baseline (incl. both nil).
        guard current != baseline else { return }
        guard let blob = current, !blob.isEmpty else {
            // Creds were cleared (logout). Update baseline so a subsequent
            // login still triggers — but don't fire yet, this is mid-flow.
            baseline = nil
            return
        }
        let cb = onChange
        stop()
        cb?(blob)
    }
}
