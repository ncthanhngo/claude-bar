import SwiftUI

/// Settings → IDE Integration. Houses the two related auto-swap helpers
/// that were previously buried inside General as a conditional reveal:
///   • Auto-reload IDE after swap (Accessibility + reload shortcut +
///     keybindings.json injection)
///   • Auto-kill CLI sessions after swap (claude-bar-watch install + alias)
///
/// Pulled out of General because the combined surface is a workflow, not a
/// preference toggle — the user opens this screen *because* they want to
/// wire Claude Bar into their editors and terminals, not because they're
/// browsing cosmetic prefs.
struct IDEIntegrationTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var axGranted = IDEReloader.isAccessibilityGranted
    @State private var installedKeybindingTargets: [KeybindingsInstaller.Target] = KeybindingsInstaller.detectInstalled()
    @State private var keybindingApplyStatus: String?

    var body: some View {
        ScrollView {
            SettingsPage {
                SettingsGroup(
                    "Editor reload",
                    subtitle: "Reload VSCode, Cursor, Windsurf, and JetBrains IDEs so extensions pick up the new account credentials after each swap."
                ) {
                    Toggle(isOn: $settings.autoReloadIDEAfterSwap) {
                        SettingsToggleLabel(
                            title: "Auto-reload IDE after swap",
                            detail: "Detected editors are reloaded the moment a swap completes. Requires Accessibility."
                        )
                    }
                    if settings.autoReloadIDEAfterSwap {
                        accessibilityStatus
                        Divider()
                        reloadShortcutSection
                    }
                }

                SettingsGroup(
                    "Terminal reload",
                    subtitle: "Restart interactive `claude` CLI sessions automatically so they re-read the new account credentials."
                ) {
                    Toggle(isOn: $settings.autoKillCLIAfterSwap) {
                        SettingsToggleLabel(
                            title: "Auto-kill CLI sessions after swap",
                            detail: "Sends SIGINT to every claude CLI process. Pair with claude-bar-watch so your terminal — including GoLand's built-in one — auto-restarts on the new account."
                        )
                    }
                    if settings.autoKillCLIAfterSwap {
                        commandRow(label: "Install claude-bar-watch once", command: installCmd)
                        commandRow(label: "Make claude auto-restart everywhere", command: aliasCmd)
                        Text("Open a new terminal tab after running the alias command. claude-bar-watch detects the credential change and restarts automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axGranted = IDEReloader.isAccessibilityGranted
        }
    }

    // MARK: - Accessibility

    private var accessibilityStatus: some View {
        HStack(spacing: 10) {
            if axGranted {
                Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else {
                Label("Accessibility required for window reload", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Spacer()
                Button("Grant Access") {
                    IDEReloader.requestAccessibilityPermission()
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        axGranted = IDEReloader.isAccessibilityGranted
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Reload shortcut

    private var reloadShortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reload shortcut")
                        .font(.caption)
                    Text("Installed into VSCode / Cursor / Windsurf / Antigravity keybindings and replayed after each swap.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                ShortcutRecorderField(
                    shortcut: Binding(
                        get: { settings.parsedReloadShortcut },
                        set: { settings.reloadShortcut = $0.vscodeString }
                    ),
                    onChange: { _ in applyReloadShortcut() }
                )
            }

            Toggle(isOn: Binding(
                get: { settings.injectReloadShortcut },
                set: { newValue in
                    settings.injectReloadShortcut = newValue
                    if newValue { applyReloadShortcut() }
                    else { removeReloadShortcut() }
                }
            )) {
                Text("Install shortcut into IDE keybindings.json")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            if settings.injectReloadShortcut {
                if installedKeybindingTargets.isEmpty {
                    Text("No supported editors detected.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text("Detected:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ForEach(installedKeybindingTargets, id: \.id) { t in
                            Text(t.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Button("Re-apply") { applyReloadShortcut() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }

            if let status = keybindingApplyStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 4)
        .onAppear {
            installedKeybindingTargets = KeybindingsInstaller.detectInstalled()
        }
    }

    private func applyReloadShortcut() {
        installedKeybindingTargets = KeybindingsInstaller.detectInstalled()
        let applied = KeybindingsInstaller.apply(shortcut: settings.parsedReloadShortcut)
        keybindingApplyStatus = applied.isEmpty
            ? "No editors found — install VSCode / Cursor / Antigravity first."
            : "Applied to \(applied.map(\.displayName).joined(separator: ", "))."
    }

    private func removeReloadShortcut() {
        let removed = KeybindingsInstaller.removeAll()
        keybindingApplyStatus = removed.isEmpty
            ? "No managed entries to remove."
            : "Removed from \(removed.map(\.displayName).joined(separator: ", "))."
    }

    // MARK: - claude-bar-watch shell snippets

    private func commandRow(label: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }

    private var installCmd: String {
        let support = ("~/Library/Application Support/claude-swap-widget/claude-bar-watch.sh" as NSString)
            .expandingTildeInPath
        let binDir = FileManager.default.fileExists(atPath: "/opt/homebrew/bin")
            ? "/opt/homebrew/bin" : "/usr/local/bin"
        return "chmod +x \"\(support)\" && ln -sf \"\(support)\" \(binDir)/claude-bar-watch"
    }

    private var aliasCmd: String {
        "grep -qxF 'alias claude=\"claude-bar-watch\"' ~/.zshrc 2>/dev/null || echo 'alias claude=\"claude-bar-watch\"' >> ~/.zshrc; grep -qxF 'alias claude=\"claude-bar-watch\"' ~/.zprofile 2>/dev/null || echo 'alias claude=\"claude-bar-watch\"' >> ~/.zprofile"
    }
}
