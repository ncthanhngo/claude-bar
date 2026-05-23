import Foundation
import AppKit
import ApplicationServices
import UserNotifications

/// Polls + surfaces the four macOS permission grants Claude Bar relies on.
/// Passive checks only — never triggers a prompt as a side effect of
/// observation; the user explicitly clicks "Open System Settings" or "Test".
@MainActor
final class PermissionsCoordinator: ObservableObject {

    enum Status: Equatable {
        case granted, denied, notDetermined, informational
    }

    @Published private(set) var accessibility: Status = .notDetermined
    @Published private(set) var notifications: Status = .notDetermined
    /// Apple Events permission can't be queried passively without prompting,
    /// so we surface it as informational until the user runs the "Test"
    /// action which performs the actual probe.
    @Published private(set) var automation: Status = .informational
    /// Network access is always available to non-sandboxed menu-bar apps;
    /// listed for transparency, not for grant/deny status.
    let networkLabel = "Always available — used for usage fetching, iCloud Drive, and any MCP services you enable."

    init() { refresh() }

    func refresh() {
        accessibility = checkAccessibility()
        Task { await refreshNotifications() }
    }

    private func checkAccessibility() -> Status {
        // Pass `prompt = false` so this is purely observational.
        let options: [String: Bool] = ["AXTrustedCheckOptionPrompt": false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary) ? .granted : .denied
    }

    private func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status: Status
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: status = .granted
        case .denied:        status = .denied
        case .notDetermined: status = .notDetermined
        @unknown default:    status = .notDetermined
        }
        self.notifications = status
    }

    // MARK: - Deep-link helpers

    static func openSystemSettings(_ pane: SystemSettingsPane) {
        guard let url = URL(string: pane.url) else { return }
        NSWorkspace.shared.open(url)
    }

    enum SystemSettingsPane {
        case accessibility, automation, notifications

        var url: String {
            switch self {
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .automation:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            case .notifications:
                return "x-apple.systempreferences:com.apple.preference.notifications?id=dev.ncthanhngo.claude-bar"
            }
        }
    }

    /// Trigger the Notifications prompt again. Only effective if the user
    /// hasn't previously denied — macOS suppresses re-prompts after a deny.
    func requestNotificationsAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in await self?.refreshNotifications() }
        }
    }
}
