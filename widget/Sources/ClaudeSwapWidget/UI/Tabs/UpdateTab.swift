import SwiftUI

/// Settings → Update.
///
/// One tab consolidating everything the user cares about for keeping the
/// app current: the auto-update preference (previously in General →
/// Updates), the manual "Check for updates…" button (previously in
/// About), the version + channel badge + build date, and the release
/// notes for the currently installed build. AboutTab stops carrying
/// these so version/changelog/auto-update lives in exactly one place —
/// the user no longer has to remember which screen surfaced what.
///
/// Release notes are pulled from `CBReleaseWhatsNew` /
/// `CBReleaseHotfixes` / `CBReleaseKnownIssues` keys in Info.plist; the
/// release-cutting skill (`/rl`) populates them before each signed
/// build, so what the user reads here is exactly what shipped, not a
/// summary written after the fact.
struct UpdateTab: View {
    @EnvironmentObject private var updateController: UpdateController

    var body: some View {
        SettingsPage {
            autoUpdateGroup
            currentBuildGroup
            releaseNotesGroup
            manualCheckGroup
            // Legacy Diagnostics groups (iCloud sync wizard, schema /
            // verify / refresh, logs, web-usage diagnostics) appended
            // here as the catch-all "advanced" surface. The Diagnostics
            // sidebar slot was retired; users who need this content
            // scroll to the bottom of Update.
            advancedHeader
            DiagnosticsTab()
        }
    }

    /// Visual separator so the user reads "I'm leaving the update
    /// section now, this is the catch-all advanced stuff" rather than
    /// mistaking the iCloud / verify groups for part of the release flow.
    private var advancedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Advanced — moved from the old Diagnostics tab")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.top, 6)
        }
    }

    // MARK: - Auto-update

    private var autoUpdateGroup: some View {
        SettingsGroup("Automatic updates", subtitle: "Claude Bar polls GitHub for new signed builds on a daily schedule.") {
            Toggle(isOn: $updateController.autoUpdateEnabled) {
                SettingsToggleLabel(
                    title: "Auto-update Claude Bar",
                    detail: "When a new version is published, Claude Bar downloads it silently and installs it on the next idle moment — no prompt, no relaunch click. Turn off to keep manual control via the Check for updates button below."
                )
            }
            .disabled(updateController.placeholderKey)
            if updateController.placeholderKey {
                Label(
                    "Signing key placeholder — updates are disabled in this build. Generate keys via Sparkle's bin/generate_keys, paste the public key into Info.plist, then re-build.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Current build

    private var currentBuildGroup: some View {
        SettingsGroup("Installed build") {
            HStack {
                Text("Version").foregroundColor(.secondary)
                Spacer()
                Text(appVersionLabel)
                    .foregroundColor(.primary)
                    .monospacedDigit()
                channelBadge
            }
            .font(.caption)
            infoRow(label: "Build date", value: aboutInfo.buildDate)
            infoRow(label: "License", value: aboutInfo.license)
        }
    }

    // MARK: - Release notes

    @ViewBuilder
    private var releaseNotesGroup: some View {
        let whatsNew = bulletLines(forKey: "CBReleaseWhatsNew")
        let hotfixes = bulletLines(forKey: "CBReleaseHotfixes")
        let knownIssues = bulletLines(forKey: "CBReleaseKnownIssues")

        if !whatsNew.isEmpty || !hotfixes.isEmpty || !knownIssues.isEmpty {
            SettingsGroup("What's new in this version") {
                bulletGroup(title: "What's new", lines: whatsNew, color: .primary)
                bulletGroup(title: "Hotfixes", lines: hotfixes, color: .primary)
                bulletGroup(title: "Known issues", lines: knownIssues, color: .orange)
            }
        }
    }

    @ViewBuilder
    private func bulletGroup(title: String, lines: [String], color: Color) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundColor(.secondary)
                        Text(line)
                            .font(.caption)
                            .foregroundColor(color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Manual check

    private var manualCheckGroup: some View {
        SettingsGroup("Manual check", subtitle: "Use this when you've heard about a release and don't want to wait for the daily poll.") {
            HStack(spacing: 8) {
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Label("Check for updates…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!updateController.canCheck)
                Spacer()
                Button("View Releases") {
                    if let url = URL(string: aboutInfo.homepageURL + "/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
            }
            Text("Updates are EdDSA-signed. macOS may show a Gatekeeper warning until the app is notarized.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers (mirror the originals on AboutTab so this tab is
    // self-contained — moving the same logic here avoids cross-tab
    // private member access while keeping behaviour identical).

    @ViewBuilder
    private var channelBadge: some View {
        let channel = releaseChannel
        Text(channel)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(channelTint(channel).opacity(0.85))
            .clipShape(Capsule())
    }

    private func bulletLines(forKey key: String) -> [String] {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return [] }
        return raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var releaseChannel: String {
        let raw = (Bundle.main.infoDictionary?["CBReleaseChannel"] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !raw.isEmpty { return raw }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        return version.contains(".") ? "Beta" : "Stable"
    }

    private func channelTint(_ channel: String) -> Color {
        switch channel.lowercased() {
        case "stable": return .green
        case "beta":   return .orange
        default:       return .gray
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value).foregroundColor(.primary)
            Spacer()
        }
        .font(.caption)
    }

    private var aboutInfo: (buildDate: String, license: String, homepageURL: String) {
        let info = Bundle.main.infoDictionary
        return (
            buildDate: info?["CBBuildDate"] as? String ?? "unknown",
            license: info?["CBLicense"] as? String ?? "MIT",
            homepageURL: info?["CBHomepageURL"] as? String ?? "https://github.com/ncthanhngo/claude-bar"
        )
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _):                return s
        case let (_, b?):                return b
        default:                         return "dev"
        }
    }
}
