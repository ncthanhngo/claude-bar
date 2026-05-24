import SwiftUI

/// Diagnostics surface for the briefing scheduler (Phase 6). Controls:
///   - Mode: cron vs interval (interval gets a minute picker)
///   - Quiet hours: HH:MM window during which notifications are muted but
///     the pull keeps running so the next-open is instant
///   - Test notification button so the user can confirm OS permission is
///     granted without waiting for an actual delta
///
/// Persists via AppSettings (UserDefaults). Backend reads on next tick.
struct SchedulerSettingsCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var permissionGranted: Bool = false

    var body: some View {
        SettingsGroup(
            "Scheduler",
            subtitle: "Interval mode pushes Material/Critical deltas as macOS notifications; quiet hours mute the alerts but the pull keeps running."
        ) {
            modePicker
            intervalPicker
            quietHoursPickers
            HStack {
                permissionBadge
                Spacer()
                Button("Test notification") {
                    UserNotificationCenter.shared.testNotification()
                }
                .controlSize(.small)
            }
        }
        .task { permissionGranted = await UserNotificationCenter.shared.hasAuthorization() }
    }

    // MARK: - Subviews

    private var modePicker: some View {
        HStack {
            Text("Mode").font(.system(size: 12, weight: .medium))
            Spacer()
            Picker("", selection: $settings.briefingScheduleMode) {
                Text("Cron (daily)").tag("cron")
                Text("Interval (live)").tag("interval")
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
    }

    @ViewBuilder
    private var intervalPicker: some View {
        if settings.briefingScheduleMode == "interval" {
            HStack {
                Text("Interval").font(.system(size: 12))
                Spacer()
                Picker("", selection: $settings.briefingIntervalMinutes) {
                    Text("5 min").tag(5)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
    }

    private var quietHoursPickers: some View {
        HStack {
            Text("Quiet hours").font(.system(size: 12))
            Spacer()
            TextField("22:00", text: $settings.quietHoursStart)
                .frame(width: 60).textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Text("→").foregroundColor(.secondary)
            TextField("07:00", text: $settings.quietHoursEnd)
                .frame(width: 60).textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private var permissionBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(permissionGranted ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(permissionGranted ? "Notification permission granted" : "Permission not granted — enable in System Settings")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
