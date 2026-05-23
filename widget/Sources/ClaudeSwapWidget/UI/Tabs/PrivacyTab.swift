import SwiftUI
import AppKit

/// Privacy / permissions transparency. Lists every macOS permission Claude
/// Bar asks for, shows current grant status, and deep-links to the matching
/// System Settings pane so the user can fix accidental denials in one click.
struct PrivacyTab: View {
    @StateObject private var coord = PermissionsCoordinator()

    var body: some View {
        ScrollView {
            SettingsPage {
                SettingsGroup(
                    "Privacy & Permissions",
                    subtitle: "Claude Bar asks for the minimum macOS permissions needed for each feature. Everything below is opt-in — nothing leaves your Mac without your explicit click."
                ) {
                    permissionRow(
                        icon: "accessibility",
                        title: "Accessibility",
                        why: "Required to reload VSCode/Cursor/etc. after a swap so the new credentials take effect.",
                        status: coord.accessibility,
                        deepLink: .accessibility,
                        testAction: nil
                    )
                    permissionRow(
                        icon: "applescript",
                        title: "Apple Events / Automation",
                        why: "Used to open Terminal so you can run `claude /login` when adding an account.",
                        status: coord.automation,
                        deepLink: .automation,
                        testAction: nil
                    )
                    permissionRow(
                        icon: "bell.badge",
                        title: "Notifications",
                        why: "Used to tell you when auto-swap kicks in, or when a swap completes.",
                        status: coord.notifications,
                        deepLink: .notifications,
                        testAction: { coord.requestNotificationsAuthorization() }
                    )
                    permissionRow(
                        icon: "network",
                        title: "Network",
                        why: coord.networkLabel,
                        status: .informational,
                        deepLink: nil,
                        testAction: nil
                    )
                    HStack {
                        Spacer()
                        Button {
                            coord.refresh()
                        } label: {
                            Label("Refresh status", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Refresh permission statuses")
                    }
                    .padding(.top, 4)
                }
            }
        }
        .onAppear { coord.refresh() }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        why: String,
        status: PermissionsCoordinator.Status,
        deepLink: PermissionsCoordinator.SystemSettingsPane?,
        testAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                statusBadge(status)
            }
            Text(why)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if deepLink != nil || testAction != nil {
                HStack(spacing: 8) {
                    if let pane = deepLink {
                        Button {
                            PermissionsCoordinator.openSystemSettings(pane)
                        } label: {
                            Label("Open System Settings…", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if let action = testAction {
                        Button("Test", action: action)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            Divider().opacity(0.4)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) permission, \(statusLabel(status))")
    }

    private func statusBadge(_ status: PermissionsCoordinator.Status) -> some View {
        switch status {
        case .granted:        return SettingsBadge(text: "GRANTED", color: .green)
        case .denied:         return SettingsBadge(text: "DENIED", color: .red)
        case .notDetermined:  return SettingsBadge(text: "NOT ASKED", color: .secondary)
        case .informational:  return SettingsBadge(text: "INFO", color: .blue)
        }
    }

    private func statusLabel(_ status: PermissionsCoordinator.Status) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "not yet requested"
        case .informational: return "informational"
        }
    }
}
