import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for Phase-6 push.
/// QuietHoursPolicy mutes Critical posts inside the user's configured
/// window; Material/Background never post (UI badge only).
@MainActor
final class UserNotificationCenter {
    static let shared = UserNotificationCenter()
    private let center = UNUserNotificationCenter.current()

    func hasAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// One-shot test notification fired from the SchedulerSettingsCard
    /// "Test notification" button. Bypasses quiet hours so the user can
    /// confirm permission works.
    func testNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Claude Bar"
        content.body = "Test notification — scheduler delta posts will look like this."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "claude-bar-test-\(Date().timeIntervalSince1970)",
                                        content: content,
                                        trigger: nil)
        center.add(req) { _ in }
    }

    /// Post a delta notification. Suppressed when QuietHoursPolicy says so.
    func postDelta(title: String, body: String, commitmentID: String?) {
        guard !QuietHoursPolicy.isQuietNow() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let id = commitmentID {
            content.userInfo = ["commitmentId": id]
        }
        let req = UNNotificationRequest(identifier: "claude-bar-delta-\(commitmentID ?? UUID().uuidString)",
                                        content: content,
                                        trigger: nil)
        center.add(req) { _ in }
    }
}

/// Quiet hours policy. Reads HH:MM strings from AppSettings; empty start +
/// empty end disables the policy entirely.
@MainActor
enum QuietHoursPolicy {
    /// True when the current local time falls inside [start, end). Handles
    /// wraparound: start=22:00 end=07:00 means quiet 22:00 → 07:00.
    static func isQuietNow(_ now: Date = Date()) -> Bool {
        let start = AppSettings.shared.quietHoursStart
        let end = AppSettings.shared.quietHoursEnd
        guard let (sh, sm) = parseHHMM(start), let (eh, em) = parseHHMM(end) else {
            return false
        }
        let cal = Calendar.current
        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        let nowMin = h * 60 + m
        let startMin = sh * 60 + sm
        let endMin = eh * 60 + em
        if startMin == endMin { return false }
        if startMin < endMin {
            return nowMin >= startMin && nowMin < endMin
        }
        // wraparound (e.g. 22:00 → 07:00)
        return nowMin >= startMin || nowMin < endMin
    }

    private static func parseHHMM(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              (0...23).contains(h),
              (0...59).contains(m) else { return nil }
        return (h, m)
    }
}
