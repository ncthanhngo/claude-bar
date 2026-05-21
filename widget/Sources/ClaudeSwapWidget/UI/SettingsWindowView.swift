import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var loginCoordinator: LoginCoordinator
    @EnvironmentObject var verifyCoordinator: VerifyCoordinator
    @EnvironmentObject var webFallback: WebFallbackCoordinator
    @EnvironmentObject var cloudSync: CloudSyncCoordinator
    @State private var showPassphraseEntry = false
    @State private var passphraseField = ""
    @State private var passphraseError: String?
    @State private var axGranted = IDEReloader.isAccessibilityGranted
    @State private var ideTestResult: String = ""
    @State private var ideTestRunning = false
    @State private var showRestoreBackupSheet = false
    @State private var restoreBackupPassphrase = ""
    @State private var restoreSelectedSlot: Int?
    @State private var restoreConfirmSlot: Int?
    @State private var installedKeybindingTargets: [KeybindingsInstaller.Target] = KeybindingsInstaller.detectInstalled()
    @State private var keybindingApplyStatus: String?

    var body: some View {
        TabView {
            accountsTab.tabItem { Label("Accounts", systemImage: "person.2") }
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            autoSwapTab.tabItem { Label("Auto-swap", systemImage: "arrow.triangle.2.circlepath") }
            LocalMCPSettingsView().tabItem { Label("Local MCP", systemImage: "puzzlepiece.extension") }
            diagnosticsTab.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 480)
        .sheet(isPresented: $showPassphraseEntry) { passphraseSheet }
        .sheet(isPresented: $showRestoreBackupSheet, onDismiss: {
            cloudSync.clearBackups()
            restoreSelectedSlot = nil
            restoreConfirmSlot = nil
        }) { restoreBackupSheet }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axGranted = IDEReloader.isAccessibilityGranted
        }
    }

    // MARK: - Accounts tab

    private var accountsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snap = store.snapshot, !snap.accounts.isEmpty {
                VStack(spacing: 2) {
                    ForEach(snap.accounts) { acc in
                        accountManageRow(acc)
                    }
                }
            } else {
                Text("No accounts added yet.")
                    .foregroundColor(.secondary).font(.callout)
            }
            Divider()
            Button {
                loginCoordinator.begin()
            } label: {
                Label("Add account", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func accountManageRow(_ acc: AccountViewDTO) -> some View {
        HStack(spacing: 10) {
            AvatarView(
                initial: acc.account.initial,
                seed: acc.account.email + (acc.account.organizationUuid ?? ""),
                size: 28
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(acc.account.displayName).font(.system(size: 13, weight: .medium))
                    if acc.isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold)).tracking(0.4)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green).clipShape(Capsule())
                    }
                }
                Text(acc.account.email).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !acc.isActive {
                Button(role: .destructive) {
                    Task { await store.remove(acc.account.number) }
                } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Remove account")
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(acc.isActive ? Color.green.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - General tab

    private var generalTab: some View {
        SettingsPage {
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
                                // "auto" chip — half black / half white
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

    private var autoSwapTab: some View {
        SettingsPage {
            SettingsGroup("Auto-swap", subtitle: "Automatically move to a lower-usage account after the active 5-hour quota reaches your threshold.") {
                Toggle("Enable auto-swap", isOn: $settings.autoSwapEnabled)
                HStack(spacing: 12) {
                    Text("Threshold")
                        .frame(width: 120, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(settings.thresholdPct) },
                        set: { settings.thresholdPct = Int($0) }
                    ), in: 1...100, step: 1)
                    Text("\(settings.thresholdPct)%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                Stepper(value: $settings.sessionPollIntervalSec, in: 2...30) {
                    valueRow(title: "Check Claude sessions every", value: "\(settings.sessionPollIntervalSec)s")
                }
            }

            SettingsGroup("How it works") {
                Text("Trigger is based on the 5-hour quota only. When the active account crosses the threshold, the widget waits until you exit claude, then swaps to the inactive account with the lowest 5-hour usage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The widget never kills running claude processes. The 7-day window is shown in the dropdown for reference but does not affect auto-swap.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diagnosticsTab: some View {
        SettingsPage {
            SettingsGroup("iCloud Sync", subtitle: "Encrypt and store accounts plus local MCP connectors in iCloud Drive. Restore on any Mac with the same Apple ID and passphrase.") {
                if let status = cloudSync.status, status.exists {
                    HStack(spacing: 6) {
                        badge("BUNDLE FOUND", color: .green)
                        if let pushed = status.pushedAt {
                            Text("Last pushed \(relativeDate(pushed))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if let n = status.backupCount, n > 0 {
                            Text("· \(n) backup\(n == 1 ? "" : "s")")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if let seq = status.lastSeenSeq, seq > 0 {
                            Text("· seq \(seq)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                } else {
                    badge("NOT SET UP", color: .secondary)
                }
                if let err = cloudSync.lastError {
                    Text(err).font(.caption).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        passphraseField = cloudSync.loadPassphrase() ?? ""
                        passphraseError = nil
                        cloudSync.passphraseIntent = .push
                        showPassphraseEntry = true
                    } label: {
                        Label(cloudSync.status?.exists == true ? "Push update" : "Enable sync",
                              systemImage: "icloud.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent).disabled(cloudSync.isBusy)

                    if cloudSync.status?.exists == true {
                        Button {
                            passphraseField = cloudSync.loadPassphrase() ?? ""
                            passphraseError = nil
                            cloudSync.passphraseIntent = .pull
                            showPassphraseEntry = true
                        } label: {
                            Label("Restore", systemImage: "icloud.and.arrow.down")
                        }
                        .buttonStyle(.bordered).disabled(cloudSync.isBusy)

                        if (cloudSync.status?.backupCount ?? 0) > 0 {
                            Button {
                                restoreBackupPassphrase = cloudSync.loadPassphrase() ?? ""
                                restoreSelectedSlot = nil
                                showRestoreBackupSheet = true
                                Task {
                                    await cloudSync.listBackups(passphrase: restoreBackupPassphrase)
                                }
                            } label: {
                                Label("Restore from backup…", systemImage: "clock.arrow.circlepath")
                            }
                            .buttonStyle(.bordered).disabled(cloudSync.isBusy)
                        }

                        Button("Forget", role: .destructive) {
                            Task { await cloudSync.forget() }
                        }
                        .buttonStyle(.borderless).disabled(cloudSync.isBusy)
                    }
                }
            }
            SettingsGroup("IDE reload test", subtitle: "Runs the full reload flow now so you can see exactly what happens.") {
                Button {
                    ideTestRunning = true
                    ideTestResult = ""
                    Task {
                        ideTestResult = await IDEReloader.diagnose()
                        ideTestRunning = false
                    }
                } label: {
                    Label(ideTestRunning ? "Testing..." : "Test IDE Reload", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(ideTestRunning)

                if !ideTestResult.isEmpty {
                    Text(ideTestResult)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            SettingsGroup("Account verification", subtitle: "Checks the keychain backup, OAuth refresh, and Anthropic usage API for every managed account.") {
                Button {
                    verifyCoordinator.begin()
                } label: {
                    Label("Verify all accounts", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
            }

            SettingsGroup("Web fallback", subtitle: "Use an embedded claude.ai browser when the usage API is rate-limited by Cloudflare WAF.") {
                HStack(spacing: 8) {
                    if webFallback.isConnected {
                        badge("CONNECTED", color: .green)
                    } else {
                        badge("NOT SIGNED IN", color: .secondary)
                    }
                    Spacer()
                }
                Text("Sign in once. The session persists across launches and can be used as a fallback source for quota information.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        webFallback.open()
                    } label: {
                        Label(webFallback.isConnected ? "Open claude.ai" : "Connect to claude.ai",
                              systemImage: "globe")
                    }
                    .buttonStyle(.borderedProminent)
                    if webFallback.isConnected {
                        Button("Disconnect", role: .destructive) {
                            Task { await webFallback.disconnect() }
                        }
                    }
                    Spacer()
                }
                if let txt = webFallback.lastScrapedQuotaText {
                    Label("Last scrape: \(txt)", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var aboutTab: some View {
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
        // Add to both ~/.zshrc (interactive shells) and ~/.zprofile (login shells used by GoLand/JetBrains terminals).
        "grep -qxF 'alias claude=\"claude-watch\"' ~/.zshrc 2>/dev/null || echo 'alias claude=\"claude-watch\"' >> ~/.zshrc; grep -qxF 'alias claude=\"claude-watch\"' ~/.zprofile 2>/dev/null || echo 'alias claude=\"claude-watch\"' >> ~/.zprofile"
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

    private func formatSec(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 { return "\(minutes)m" }
        return "\(minutes)m \(remainder)s"
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
    }

    // MARK: - Passphrase sheet

    private var passphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(cloudSync.passphraseIntent == .pull ? "Restore from iCloud" : "iCloud Sync Passphrase")
                .font(.headline)
            Text(cloudSync.passphraseIntent == .pull
                 ? "Enter the passphrase you used on your other Mac. Accounts and connector tokens will be restored into this Mac's Keychain."
                 : "Choose a passphrase to encrypt your accounts and connector tokens. You will need it on any new Mac.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passphrase", text: $passphraseField)
                .textFieldStyle(.roundedBorder)

            if let err = passphraseError {
                Text(err).font(.caption).foregroundColor(.red)
            }

            HStack {
                Button("Cancel") { showPassphraseEntry = false }.buttonStyle(.bordered)
                Spacer()
                Button(cloudSync.passphraseIntent == .pull ? "Restore" : "Save & Push") {
                    guard !passphraseField.isEmpty else {
                        passphraseError = "Passphrase cannot be empty."
                        return
                    }
                    showPassphraseEntry = false
                    Task {
                        if cloudSync.passphraseIntent == .pull {
                            await cloudSync.pull(passphrase: passphraseField)
                            await store.refreshNow()
                        } else {
                            await cloudSync.push(passphrase: passphraseField)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(passphraseField.isEmpty)
            }
        }
        .padding(24).frame(width: 360)
    }

    // MARK: - Restore-from-backup sheet

    private var restoreBackupSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore from backup")
                .font(.headline)
            Text("Pick an older bundle to roll back to. Slot 0 is the current bundle; higher slots are progressively older ring-buffer copies. The current bundle is overwritten on restore.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Always allow re-entering the passphrase. The saved one may be
            // wrong (e.g. user rotated passphrase on another device) — in that
            // case every backup row comes back with decrypted=false and the
            // user needs a way to retry.
            if !cloudSync.isBusy && !cloudSync.backups.isEmpty && cloudSync.backups.allSatisfy({ !$0.decrypted }) {
                Text("Couldn't decrypt with the saved passphrase. Enter a different one to reveal seq and pushed-at for each backup.")
                    .font(.caption2).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                SecureField("Passphrase", text: $restoreBackupPassphrase)
                    .textFieldStyle(.roundedBorder)
                Button("Decrypt") {
                    Task { await cloudSync.listBackups(passphrase: restoreBackupPassphrase) }
                }
                .buttonStyle(.bordered).disabled(restoreBackupPassphrase.isEmpty || cloudSync.isBusy)
            }

            if cloudSync.isBusy && cloudSync.backups.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading…").font(.caption) }
            } else if cloudSync.backups.isEmpty {
                Text("No bundle copies found.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(cloudSync.backups) { b in
                            backupRow(b)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            if let err = cloudSync.lastError {
                Text(err).font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Close") { showRestoreBackupSheet = false }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    if let slot = restoreSelectedSlot {
                        restoreConfirmSlot = slot
                    }
                } label: {
                    Label("Restore selected", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .disabled(restoreSelectedSlot == nil || cloudSync.isBusy)
            }
        }
        .padding(20)
        .frame(width: 480)
        .confirmationDialog(
            "Restore from slot \(restoreConfirmSlot ?? 0)?",
            isPresented: Binding(
                get: { restoreConfirmSlot != nil },
                set: { if !$0 { restoreConfirmSlot = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore now", role: .destructive) {
                guard let slot = restoreConfirmSlot else { return }
                let pass = restoreBackupPassphrase.isEmpty
                    ? (cloudSync.loadPassphrase() ?? "")
                    : restoreBackupPassphrase
                restoreConfirmSlot = nil
                showRestoreBackupSheet = false
                Task {
                    await cloudSync.restoreBackup(slot: slot, passphrase: pass)
                    await store.refreshNow()
                }
            }
            Button("Cancel", role: .cancel) { restoreConfirmSlot = nil }
        } message: {
            Text("This overwrites current keychain credentials for every account in the chosen bundle. Anti-rollback is bypassed and the sync state is rewound to this bundle's seq.")
        }
    }

    private func backupRow(_ b: CswClient.CloudBackupInfoDTO) -> some View {
        let selected = restoreSelectedSlot == b.slot
        return Button {
            restoreSelectedSlot = b.slot
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(b.slot == 0 ? "Current" : "Backup #\(b.slot)")
                            .font(.system(size: 12, weight: .semibold))
                        if b.decrypted, let seq = b.seq {
                            Text("seq \(seq)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if let n = b.accountCount {
                            Text("· \(n) account\(n == 1 ? "" : "s")")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        if let pushed = b.pushedAtInBundle {
                            Text("Pushed \(relativeDate(pushed))")
                                .font(.caption2).foregroundColor(.secondary)
                        } else {
                            Text("Modified \(relativeDate(b.fileModTime))")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Text("· \(b.sizeKb) KB")
                            .font(.caption2).foregroundColor(.secondary)
                        if !b.decrypted {
                            Text("· encrypted")
                                .font(.caption2).foregroundColor(.orange)
                        }
                    }
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func relativeDate(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
