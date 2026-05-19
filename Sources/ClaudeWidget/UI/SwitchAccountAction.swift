import AppKit

/// Shared confirmation + switch logic. Called by both the popover row's
/// **Switch** button and the menubar quick-switch menu so behaviour stays
/// consistent: warn the user explicitly when `claude` CLI is running.
@MainActor
enum SwitchAccountAction {

    /// Returns true if the switch actually happened.
    @discardableResult
    static func confirmAndSwitch(store: UsageStore, account: Account) -> Bool {
        // Don't bother confirming if user clicked the already-active row.
        if store.config.activeAccountId == account.id { return false }

        let pids = ClaudeProcessDetector.runningPIDs()
        let alert = NSAlert()
        alert.messageText = "Switch to \"\(account.displayName)\"?"
        if pids.isEmpty {
            alert.informativeText = "Your Claude Code Keychain will be updated. Run `claude` to start using this account."
        } else {
            let n = pids.count
            let plural = n == 1 ? "" : "s"
            alert.alertStyle = .warning
            alert.informativeText = """
\(n) `claude` session\(plural) currently running.

Switching now updates the Keychain — new `claude` invocations will use \"\(account.displayName)\". Running sessions keep their current account in memory until you quit them or the access token refreshes (~1h), at which point they may silently pick up the new identity.

Continue?
"""
        }
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModalAbovePopover() == .alertFirstButtonReturn else { return false }

        do {
            try store.switchToAccount(id: account.id)
            AutoSwitcher.postManualSwitchNotification(to: account)
            return true
        } catch {
            store.lastError = error.localizedDescription
            return false
        }
    }
}
