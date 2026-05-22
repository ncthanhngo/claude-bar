import SwiftUI

struct AboutTab: View {
    var body: some View {
        ScrollView {
            SettingsPage {
                SettingsGroup("Claude Bar") {
                    Text("A menu-bar profile switcher for Claude Code accounts.")
                        .foregroundColor(.secondary)
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionLabel)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                        Text("Stable")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.8))
                            .clipShape(Capsule())
                    }
                    .font(.caption)
                    infoRow(label: "Build date", value: aboutInfo.buildDate)
                    infoRow(label: "License", value: aboutInfo.license)
                }
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
                SettingsGroup("Tech Stack") {
                    stackRow(label: "UI", value: "SwiftUI · macOS 14+")
                    stackRow(label: "Backend", value: "Go (csw daemon)")
                    stackRow(label: "IPC", value: "Unix socket · HTTP/JSON")
                    stackRow(label: "Auth storage", value: "macOS Keychain")
                    stackRow(label: "Cloud sync", value: "iCloud Drive · AES-256-GCM")
                    stackRow(label: "MCP connectors", value: "ClickUp · Slack · Google Drive · Google Workspace")
                }
                SettingsGroup("Legal") {
                    Text(aboutInfo.copyright)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Button("View Releases") {
                            if let url = URL(string: aboutInfo.homepageURL + "/releases") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Report Issue") {
                            if let url = URL(string: aboutInfo.homepageURL + "/issues/new") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

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

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b:
            return "\(s) (\(b))"
        case let (s?, _):
            return s
        case let (_, b?):
            return b
        default:
            return "dev"
        }
    }
}
