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
        }
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

    private func relativeDate(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
