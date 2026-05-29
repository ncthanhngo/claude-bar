import Foundation
import UserNotifications

/// Net-new `UNUserNotificationCenter` delegate that handles the Cancel/Retry
/// buttons on credential-recovery notifications. The codebase had no
/// notification delegate before this — recovery notifications only POSTED.
///
/// Registered once at app launch (`install()`): it sets itself as the center
/// delegate, registers the Cancel/Retry categories so their buttons render,
/// and routes taps back to the auto-swap state machine.
@MainActor
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    private weak var autoSwap: AutoSwapStateMachine?

    init(autoSwap: AutoSwapStateMachine) {
        self.autoSwap = autoSwap
        super.init()
    }

    /// Installs the delegate and registers categories. Must run BEFORE any
    /// recovery notification fires, or the action buttons won't appear.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let cancel = UNNotificationAction(
            identifier: AutoSwapStateMachine.Notif.cancelAction,
            title: "Cancel", options: [.destructive])
        let retry = UNNotificationAction(
            identifier: AutoSwapStateMachine.Notif.retryAction,
            title: "Retry", options: [])
        let pending = UNNotificationCategory(
            identifier: AutoSwapStateMachine.Notif.pendingCategory,
            actions: [cancel], intentIdentifiers: [], options: [])
        let failed = UNNotificationCategory(
            identifier: AutoSwapStateMachine.Notif.failedCategory,
            actions: [retry], intentIdentifiers: [], options: [])
        center.setNotificationCategories([pending, failed])
    }

    // Show recovery banners even when the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case AutoSwapStateMachine.Notif.cancelAction:
                autoSwap?.cancelActiveRecovery()
            case AutoSwapStateMachine.Notif.retryAction:
                autoSwap?.retryActiveRecovery()
            default:
                break
            }
        }
    }
}
