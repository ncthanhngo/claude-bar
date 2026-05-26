import SwiftUI
import AppKit

/// Settings → About. Opens with a hero block (app icon + name + version +
/// channel badge + manual update CTA) so the user immediately sees what
/// they're running. Author / tech stack / legal / re-run onboarding sit
/// in compact rows below the hero, none of which try to be the page's
/// focus. The earlier version was 5 prose-y SettingsGroups that opened
/// with a "go check the Update tab instead" redirect — that's an IA
/// smell; this layout makes About self-contained again.
struct AboutTab: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var loginCoordinator: LoginCoordinator
    @EnvironmentObject private var cloudSync: CloudSyncCoordinator
    @EnvironmentObject private var updateController: UpdateController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            SettingsPage {
                hero
                SettingsGroup("Author") {
                    infoRow(label: "Name", value: aboutInfo.authorName)
                    HStack(alignment: .top) {
                        Text("Email")
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Link(aboutInfo.authorEmail, destination: URL(string: "mailto:\(aboutInfo.authorEmail)")!)
                    }
                    .font(.caption)
                    HStack(alignment: .top) {
                        Text("Homepage")
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Link(aboutInfo.homepageURL, destination: URL(string: aboutInfo.homepageURL)!)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                }
                SettingsGroup("Tech stack") {
                    stackRow(label: "UI", value: "SwiftUI · macOS 14+")
                    stackRow(label: "Backend", value: "Go (csw daemon)")
                    stackRow(label: "IPC", value: "Unix socket · HTTP/JSON")
                    stackRow(label: "Auth storage", value: "macOS Keychain")
                    stackRow(label: "Cloud sync", value: "iCloud Drive · AES-256-GCM")
                    stackRow(label: "MCP connectors", value: "ClickUp · Slack · Google Drive · Google Workspace")
                }
                SettingsGroup("Welcome flow") {
                    HStack {
                        Text("Re-run the onboarding wizard to revisit the first-launch tour.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            settings.didCompleteOnboarding = false
                            OnboardingWindowController.shared.present(
                                store: store,
                                loginCoordinator: loginCoordinator,
                                settings: settings,
                                cloudSync: cloudSync
                            )
                        } label: {
                            Label("Re-run", systemImage: "arrow.uturn.left.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                SettingsGroup("Legal") {
                    Text(aboutInfo.copyright)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Button("Report Issue") {
                            if let url = URL(string: aboutInfo.homepageURL + "/issues/new") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("View Releases") {
                            if let url = URL(string: aboutInfo.homepageURL + "/releases") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Bar")
                    .font(.system(size: 22, weight: .bold))
                Text("A menu-bar profile switcher for Claude Code accounts.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(appVersionLabel)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                    channelBadge
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("Built \(aboutInfo.buildDate)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    Button {
                        updateController.checkForUpdates()
                    } label: {
                        Label("Check for updates…", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!updateController.canCheck)

                    Button {
                        if let url = URL(string: aboutInfo.homepageURL) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var channelBadge: some View {
        let channel = releaseChannel
        Text(channel.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.4)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(channelTint(channel).opacity(0.85))
            .clipShape(Capsule())
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

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "v\(s) (\(b))"
        case let (s?, _):                return "v\(s)"
        case let (_, b?):                return "build \(b)"
        default:                         return "dev"
        }
    }

    // MARK: - Row helpers

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .foregroundColor(.primary)
            Spacer()
        }
        .font(.caption)
    }

    private func stackRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .foregroundColor(.primary)
        }
        .font(.caption)
    }

    private struct AboutInfo {
        let authorName: String
        let authorEmail: String
        let homepageURL: String
        let license: String
        let buildDate: String
        let copyright: String
    }

    private var aboutInfo: AboutInfo {
        let info = Bundle.main.infoDictionary
        return AboutInfo(
            authorName: info?["CBAuthorName"] as? String ?? "Thanh Ngô",
            authorEmail: info?["CBAuthorEmail"] as? String ?? "nc.thanhngo@gmail.com",
            homepageURL: info?["CBHomepageURL"] as? String ?? "https://github.com/ncthanhngo/claude-bar",
            license: info?["CBLicense"] as? String ?? "MIT",
            buildDate: info?["CBBuildDate"] as? String ?? "unknown",
            copyright: info?["NSHumanReadableCopyright"] as? String ?? "Copyright © Thanh Ngô"
        )
    }
}
