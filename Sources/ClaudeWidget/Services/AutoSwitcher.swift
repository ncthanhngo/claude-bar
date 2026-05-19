import Foundation
import UserNotifications

/// Decides whether the active account's session % crossed the user's switch
/// threshold, picks a candidate, and performs the switch.
@MainActor
enum AutoSwitcher {

    enum SwitchOutcome {
        case skipped(reason: String)
        case switched(to: Account)
        case failed(error: String)
    }

    /// Pure decision: returns the account to switch to, or nil if no action.
    ///
    /// Strategy:
    ///  1. If any non-active account has a known `lastSessionPercent`, pick
    ///     the one with the lowest value. This is the safe path — we know
    ///     where we're switching to and it has headroom.
    ///  2. If NO non-active account has been observed yet (polling never ran
    ///     or always failed), fall back to the first non-active account by
    ///     creation order. Deterministic but blind.
    static func chooseCandidate(
        activeId: UUID?,
        accounts: [Account],
        currentPercent: Double,
        threshold: Double
    ) -> Account? {
        guard accounts.count >= 2 else { return nil }
        guard currentPercent >= threshold else { return nil }
        let others = accounts.filter { $0.id != activeId }
        let withData = others.filter { $0.lastSessionPercent != nil }
        if !withData.isEmpty {
            return withData.min { ($0.lastSessionPercent ?? .infinity) < ($1.lastSessionPercent ?? .infinity) }
        }
        return others.first
    }

    /// Side-effect: switches Claude Code's keychain and posts a notification.
    @discardableResult
    static func performSwitch(to account: Account) -> SwitchOutcome {
        do {
            let switched = try AccountStore.switchTo(id: account.id)
            postSwitchNotification(to: switched)
            return .switched(to: switched)
        } catch {
            return .failed(error: error.localizedDescription)
        }
    }

    // MARK: - Notifications

    private static var notificationsAuthorized = false

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            notificationsAuthorized = granted
        }
    }

    private static func postSwitchNotification(to account: Account) {
        post(
            title: "Switched to \(account.displayName)",
            body: "Previous account hit the usage threshold. Run `claude` to start using the new login."
        )
    }

    /// Notification triggered by manual account switch from popover or
    /// menubar. Phrased differently from the auto-switch one (no threshold
    /// context) so the user knows whose action it was.
    static func postManualSwitchNotification(to account: Account) {
        post(
            title: "Switched to \(account.displayName)",
            body: "Run `claude` to start using this account."
        )
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Fired when threshold is hit but switch is deferred because `claude` is
    /// still running. Tells the user the switch will happen automatically.
    static func postPendingNotification(to account: Account, sessionCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Usage threshold reached"
        let plural = sessionCount == 1 ? "" : "s"
        content.body = "Will switch to \(account.displayName) once \(sessionCount) running `claude` session\(plural) quit."
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
