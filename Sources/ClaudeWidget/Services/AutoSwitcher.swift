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
    static func chooseCandidate(
        activeId: UUID?,
        accounts: [Account],
        currentPercent: Double,
        threshold: Double
    ) -> Account? {
        guard accounts.count >= 2 else { return nil }
        guard currentPercent >= threshold else { return nil }
        let others = accounts.filter { $0.id != activeId }
        // Prefer accounts with the lowest known usage; ties broken by oldest
        // observation. Unobserved accounts come first.
        return others.min { lhs, rhs in
            switch (lhs.lastSessionPercent, rhs.lastSessionPercent) {
            case (nil, nil):    return (lhs.lastObservedAt ?? .distantPast) < (rhs.lastObservedAt ?? .distantPast)
            case (nil, _):      return true
            case (_, nil):      return false
            case let (l?, r?):  return l < r
            }
        }
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
        let content = UNMutableNotificationContent()
        content.title = "Switched to \(account.displayName)"
        content.body = "Previous account hit the usage threshold. Restart Claude Code to use the new login."
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
