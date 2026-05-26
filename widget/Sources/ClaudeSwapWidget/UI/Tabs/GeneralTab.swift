import SwiftUI

struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var loginCoordinator: LoginCoordinator
    @State private var axGranted = IDEReloader.isAccessibilityGranted
    @State private var installedKeybindingTargets: [KeybindingsInstaller.Target] = KeybindingsInstaller.detectInstalled()
    @State private var keybindingApplyStatus: String?

    var body: some View {
        ScrollView {
            SettingsPage {
                SettingsGroup("Accounts", subtitle: "Add a new Claude Code account to Claude Bar's roster.") {
                    Button {
                        loginCoordinator.begin()
                    } label: {
                        Label("Add Claude Code account…", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Opens the guided setup window — also accessible from the header on the menu-bar popover.")
                }

                SettingsGroup("Menu bar") {
                    Picker("Display style", selection: $settings.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                    Divider()
                    iconColorPicker
                }

                SettingsGroup("Popover layout", subtitle: "Choose how much information the menu-bar popover shows. The popover auto-opens when you pick a layout so you can preview the result.") {
                    Picker("Layout", selection: $settings.popoverLayout) {
                        ForEach(PopoverLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360, alignment: .leading)
                    .onChange(of: settings.popoverLayout) { _, _ in
                        // Settings lives in its own NSWindow; clicking a
                        // segment steals key focus from the popover, which
                        // dismisses on focus loss. Reopen after a short
                        // delay so the dismissal settles first, otherwise
                        // performClick would arrive while SwiftUI's
                        // "popover is shown" flag is still mid-transition
                        // and the click would silently no-op.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            MenuBarPopoverToggle.openIfClosed()
                        }
                    }
                    Text(settings.popoverLayout.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsGroup("IDE integration", subtitle: "Optional helpers for keeping editors and terminal sessions aligned after a swap.") {
                    Toggle(isOn: $settings.autoReloadIDEAfterSwap) {
                        SettingsToggleLabel(
                            title: "Auto-reload IDE after swap",
                            detail: "Reloads VSCode, Cursor, Windsurf, and JetBrains IDEs (GoLand, IntelliJ, etc.) so extensions pick up the new account."
                        )
                    }
                    if settings.autoReloadIDEAfterSwap {
                        accessibilityStatus
                        Divider()
                        reloadShortcutSection
                    }

                    Divider()

                    Toggle(isOn: $settings.autoKillCLIAfterSwap) {
                        SettingsToggleLabel(
                            title: "Auto-kill CLI sessions after swap",
                            detail: "Sends SIGINT to every claude CLI process. Use with claude-watch so the terminal auto-restarts on the new account (including GoLand's built-in terminal)."
                        )
                    }
                    if settings.autoKillCLIAfterSwap {
                        commandRow(label: "Install claude-watch once", command: installCmd)
                        commandRow(label: "Make claude auto-restart everywhere", command: aliasCmd)
                        Text("Open a new terminal tab after running the alias command. claude-watch detects the credential change and restarts automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                SettingsGroup("Adaptive refresh", subtitle: "The widget refreshes faster when the active 5-hour usage approaches the auto-swap threshold.") {
                    refreshStepper(
                        title: "Normal refresh",
                        value: $settings.refreshIntervalSec,
                        range: 30...900,
                        step: 30,
                        detail: "When 5h usage is below \(settings.adaptiveHighThresholdPct)%"
                    )
                    refreshStepper(
                        title: "Fast refresh",
                        value: $settings.refreshIntervalHighSec,
                        range: 30...600,
                        step: 30,
                        detail: "When 5h usage is \(settings.adaptiveHighThresholdPct)% or higher"
                    )
                    Stepper(value: $settings.adaptiveHighThresholdPct, in: 50...95, step: 5) {
                        valueRow(title: "Fast refresh starts at", value: "\(settings.adaptiveHighThresholdPct)%")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axGranted = IDEReloader.isAccessibilityGranted
        }
    }

    private var iconColorPicker: some View {
        HStack(spacing: 0) {
            Text("Icon color")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Spacer()
            HStack(spacing: 5) {
                ForEach(MenuBarIconColor.allCases) { c in
                    Button {
                        settings.menuBarIconColor = c
                    } label: {
                        ZStack {
                            if c == .system {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [.black, .white],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: 18, height: 18)
                            } else {
                                Circle()
                                    .fill(c.color ?? .primary)
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                            }
                            if settings.menuBarIconColor == c {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(c == .white || c == .yellow ? .black : .white)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(c.label)
                }
            }
        }
    }

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

    private func refreshStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        detail: String
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            VStack(alignment: .leading, spacing: 2) {
                valueRow(title: title, value: formatSec(value.wrappedValue))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .fontWeight(.medium)
                .foregroundColor(.accentColor)
        }
    }

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
        let support = ("~/Library/Application Support/claude-swap-widget/claude-watch.sh" as NSString)
            .expandingTildeInPath
        let binDir = FileManager.default.fileExists(atPath: "/opt/homebrew/bin")
            ? "/opt/homebrew/bin" : "/usr/local/bin"
        return "chmod +x \"\(support)\" && ln -sf \"\(support)\" \(binDir)/claude-watch"
    }

    private var aliasCmd: String {
        "grep -qxF 'alias claude=\"claude-watch\"' ~/.zshrc 2>/dev/null || echo 'alias claude=\"claude-watch\"' >> ~/.zshrc; grep -qxF 'alias claude=\"claude-watch\"' ~/.zprofile 2>/dev/null || echo 'alias claude=\"claude-watch\"' >> ~/.zprofile"
    }

    private func formatSec(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 { return "\(minutes)m" }
        return "\(minutes)m \(remainder)s"
    }
}
