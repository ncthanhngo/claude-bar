import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hook set by `ClaudeSwapWidgetApp.init()` to capture the @StateObject
    /// coordinators in a closure that `applicationDidFinishLaunching` can
    /// invoke. We can't rely on MenuBarExtra's `.task` for launch-time work
    /// because that closure only fires when the popover content is first
    /// rendered — which may be never if the user never opens the popover.
    nonisolated(unsafe) static var onLaunchCompleted: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // menu bar app — never quit just because a window closed
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.onLaunchCompleted?()
        // Single-shot; don't fire on subsequent NSApp reactivations.
        Self.onLaunchCompleted = nil
    }
}

@main
struct ClaudeSwapWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var loginCoordinator = LoginCoordinator()
    @StateObject private var verifyCoordinator = VerifyCoordinator()
    @StateObject private var webFallback = WebFallbackCoordinator()
    @StateObject private var quickRelogin = QuickReloginCoordinator()
    @StateObject private var recovery = CredentialRecoveryCoordinator()
    @StateObject private var cloudSync = CloudSyncCoordinator(client: CswClient())
    @StateObject private var localMCP = LocalMCPCoordinator(client: CswClient())
    @StateObject private var chatStore = ChatStore()
    @StateObject private var prefsCloudSync = PreferencesCloudSync.shared
    @StateObject private var updateController = UpdateController()
    @StateObject private var gateCoord = GateCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared

    init() {
        // Diagnostics first so anything that crashes during the rest of init
        // (ClaudeBarWatchInstaller, settings migration, hotkey wiring) lands
        // in ~/Library/Logs/ClaudeBar/.
        DiagnosticsLogger.shared.bootstrap()
        CrashHandler.install()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        ClaudeBarWatchInstaller.install()
        CmuxConfigInstaller.install()
        migrateSettingsIfNeeded()
        // Reset the iCloud-sync toggle to false on every Sparkle update
        // BEFORE any later startup code touches the cloud-sync passphrase
        // Keychain item. Previously this lived inside the popover's .task,
        // which only fires when the user opens the popover for the first
        // time — so a Sparkle background update + a user who hadn't yet
        // opened the popover would let `backupTokenRefreshIfNeeded` (kicked
        // off from `store.start()`) call `loadPassphrase()` while the
        // stale `iCloudSyncEnabled = true` value from the previous version
        // was still live. The new code signature then hit the Keychain
        // ACL, triggering the macOS "Allow access?" password dialog.
        resetICloudSyncToggleOnVersionChange()
        seedAutoApproveSlackPostMessageDefault()
        syncReloadShortcutIfNeeded()

        // GateCoordinator is a singleton (`.shared`) so it can safely run
        // before any view materialises. Everything else gets wired from
        // MenuBarLabelView.onAppear — see `wireCoordinatorsOnce` for the
        // reasoning around @StateObject identity in App.init().
        AppDelegate.onLaunchCompleted = {
            Task { @MainActor in
                DiagnosticsLogger.shared.log(.info, subsystem: "launch", "AppDelegate didFinishLaunching")
                GateCoordinator.shared.start()
            }
        }
    }

    /// Keep the configured reload shortcut in sync with each VSCode-family
    /// editor's keybindings.json on launch. Skips work when state file already
    /// reflects the current shortcut + all detected targets.
    @MainActor
    private func syncReloadShortcutIfNeeded() {
        let settings = AppSettings.shared
        guard settings.injectReloadShortcut else { return }
        let want = settings.parsedReloadShortcut.vscodeString
        let state = KeybindingsInstaller.loadState()
        let installedIds = Set(KeybindingsInstaller.detectInstalled().map(\.id))
        let appliedIds = Set(state?.appliedTargets ?? [])
        let needsApply = state?.lastShortcut != want || !installedIds.isSubset(of: appliedIds)
        guard needsApply else { return }
        KeybindingsInstaller.apply(shortcut: settings.parsedReloadShortcut)
    }

    /// Copy settings from the old bundle ID (dev.soi.claude-swap-widget) to the
    /// new one (dev.ncthanhngo.claude-bar) when migrating for the first time.
    private func migrateSettingsIfNeeded() {
        let newDomain = "dev.ncthanhngo.claude-bar"
        let oldDomain = "dev.soi.claude-swap-widget"
        let migrationKey = "settingsMigratedFromLegacyDomain"

        let newDefaults = UserDefaults(suiteName: newDomain) ?? .standard
        guard !newDefaults.bool(forKey: migrationKey) else { return }

        if let old = UserDefaults(suiteName: oldDomain) {
            let keys = [
                "autoKillCLIAfterSwap", "autoReloadIDEAfterSwap", "autoSwapEnabled",
                "thresholdPct", "menuBarStyle", "refreshIntervalSec",
                "refreshIntervalHighSec", "adaptiveHighThresholdPct",
                "sessionPollIntervalSec", "widgetTheme"
            ]
            for key in keys {
                if let val = old.object(forKey: key) {
                    newDefaults.set(val, forKey: key)
                }
            }
        }
        newDefaults.set(true, forKey: migrationKey)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot()
                .environmentObject(store)
                .environmentObject(loginCoordinator)
                .environmentObject(verifyCoordinator)
                .environmentObject(webFallback)
                .environmentObject(quickRelogin)
                .environmentObject(recovery)
                .environmentObject(cloudSync)
                .environmentObject(localMCP)
                .environmentObject(updateController)
                .environmentObject(gateCoord)
                // Write-gate sheet for Low / Medium / ReadSensitive prompts.
                // Without this, those prompts only render via the
                // ConfirmGateOverlay inside the popover — invisible when the
                // popover is closed, so MCP write calls (Slack post, ClickUp
                // comment, etc.) time out after 30s without the user ever
                // seeing the prompt. The `isPresented` binding must accept
                // writes too — a no-op setter would leave SwiftUI thinking
                // the sheet is in-flight forever.
                .sheet(isPresented: Binding(
                    get: { gateCoord.pending.map { $0.risk != .destructive } ?? false },
                    set: { isOpen in if !isOpen { gateCoord.cancel() } }
                )) {
                    ConfirmGateView(gate: gateCoord)
                        .frame(width: 460)
                        .padding(20)
                        .background(Color(NSColor.windowBackgroundColor))
                }
                .task {
                    // All launch-time wiring (timer start, coordinator
                    // attaches, notification handler) now fires from
                    // AppDelegate.applicationDidFinishLaunching via
                    // onLaunchCompleted, so background polling and auto-swap
                    // come up without requiring the user to open the popover
                    // first. Kept as an explicit empty hook to document the
                    // move — anything popover-render-specific in the future
                    // belongs here.
                }
        } label: {
            MenuBarLabelView()
                .environmentObject(store)
                .onAppear {
                    // Wire coordinators from the LABEL's onAppear — not the
                    // popover content's `.task` (lazy, popover-only) and not
                    // AppDelegate.applicationDidFinishLaunching (the
                    // `_xxx.wrappedValue` access inside App.init() materialises
                    // a TRANSIENT @StateObject instance that views never see;
                    // the launch closure's attach() targets the transient
                    // coordinator with a transient store, both deallocate when
                    // the closure releases, leaving the views' real
                    // coordinators with `weak var store == nil` → "Internal
                    // error: no store reference" in Quick Login). The label is
                    // rendered as the menu-bar icon at app start, so onAppear
                    // here fires at launch AND the @StateObject references in
                    // the surrounding App are the persistent instances views
                    // actually use.
                    wireCoordinatorsOnce()
                }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private func wireCoordinatorsOnce() {
        guard !Self.didWireCoordinators else { return }
        Self.didWireCoordinators = true
        DiagnosticsLogger.shared.log(.info, subsystem: "launch", "begin wireCoordinatorsOnce")
        loginCoordinator.attach(store: store)
        verifyCoordinator.attach(store: store)
        webFallback.attach(store: store)
        quickRelogin.attach(store: store, webFallback: webFallback, loginCoordinator: loginCoordinator)
        loginCoordinator.quickRelogin = quickRelogin
        recovery.headlessRelogin = { [weak quickRelogin] accountNum in
            await quickRelogin?.beginHeadless(forAccountNumber: accountNum)
                ?? .failed("no coordinator")
        }
        store.recovery = recovery
        let notifHandler = NotificationActionHandler(autoSwap: store.autoSwap)
        notifHandler.install()
        store.notificationHandler = notifHandler
        store.autoSwap.recovery = recovery
        store.autoSwap.isInteractiveReloginActive = { [weak quickRelogin] in
            quickRelogin?.isPresentingInteractive ?? false
        }
        store.cloudSync = cloudSync
        DiagnosticsLogger.shared.log(.info, subsystem: "launch", "coordinators wired")
        store.start()
        chatStore.bind(to: store)
        DiagnosticsLogger.shared.log(.info, subsystem: "launch", "polling started")
        let storeBind = store
        let loginBind = loginCoordinator
        let verifyBind = verifyCoordinator
        let webBind = webFallback
        let quickBind = quickRelogin
        let cloudBind = cloudSync
        let mcpBind = localMCP
        let updateBind = updateController
        let gateBind = gateCoord
        SettingsWindowController.shared.bindEnvironment { content in
            AnyView(
                content
                    .environmentObject(storeBind)
                    .environmentObject(loginBind)
                    .environmentObject(verifyBind)
                    .environmentObject(webBind)
                    .environmentObject(quickBind)
                    .environmentObject(cloudBind)
                    .environmentObject(mcpBind)
                    .environmentObject(updateBind)
                    .environmentObject(gateBind)
            )
        }
        prefsCloudSync.start()
        Task { @MainActor in
            await cloudSync.refreshStatus()
            await cloudSync.checkOnboarding(snapshot: store.snapshot)
            DiagnosticsLogger.shared.log(.info, subsystem: "launch", "cloud sync ready (enabled=\(AppSettings.shared.iCloudSyncEnabled))")
            try? await Task.sleep(nanoseconds: 800_000_000)
            presentOnboardingIfNeeded()
            DiagnosticsLogger.shared.log(.info, subsystem: "launch", "end wireCoordinatorsOnce")
        }
        Task.detached(priority: .utility) { [localMCP] in
            await localMCP.refresh()
        }
    }

    nonisolated(unsafe) private static var didWireCoordinators = false

    /// Show the first-launch onboarding window when the user has no accounts
    /// AND hasn't already finished or skipped the wizard. Triggered after
    /// the first `store.start()` snapshot arrives so we don't flash the
    /// wizard while data is loading.
    ///
    /// Also called from `AppDelegate.applicationDidFinishLaunching` via the
    /// `onLaunchCompleted` bridge so onboarding fires even if the user
    /// never opens the popover (the `.task` modifier on MenuBarExtra
    /// content is lazy).
    @MainActor
    private func presentOnboardingIfNeeded() {
        presentOnboardingIfNeededAtLaunch(
            store: store,
            loginCoordinator: loginCoordinator,
            settings: settings,
            cloudSync: cloudSync
        )
    }

    /// Every Sparkle update lands on a clean default-off iCloud sync toggle.
    /// We compare the running `CFBundleShortVersionString` against the last
    /// version we recorded; if they differ (fresh install OR upgrade) the
    /// toggle is reset to false. Within the same version the toggle keeps
    /// the user's choice, so flipping it on once per release sticks until
    /// the next update. Keychain item is left intact so re-enabling the
    /// toggle reuses the saved passphrase without a re-prompt.
    /// Seed the auto-approve toggle to ON for users who have never touched
    /// it — handles fresh installs and existing users on builds that
    /// shipped before the default flipped to true. Once UserDefaults has
    /// a value (user toggled, or this seed ran), we leave the user's
    /// choice alone. Always re-emits the policy JSON the Go MCP process
    /// reads so the backend stays in sync without waiting for the
    /// settings view's .task to fire.
    @MainActor
    private func seedAutoApproveSlackPostMessageDefault() {
        let key = "autoApproveSlackPostMessage"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }
        MCPWritePolicyWriter.write(autoApproveSlackPostMessage: settings.autoApproveSlackPostMessage)
    }

    @MainActor
    private func resetICloudSyncToggleOnVersionChange() {
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard !current.isEmpty else { return }
        if settings.lastLaunchedAppVersion != current {
            settings.iCloudSyncEnabled = false
            settings.lastLaunchedAppVersion = current
        }
    }
}

/// Static helper shared between the popover-`.task` and the AppDelegate
/// launch hook. Static so it can be called from a closure captured at
/// `init()` time without holding `self`. Idempotent —
/// `OnboardingWindowController.present()` short-circuits when the window
/// is already up.
@MainActor
private func presentOnboardingIfNeededAtLaunch(
    store: AppStore,
    loginCoordinator: LoginCoordinator,
    settings: AppSettings,
    cloudSync: CloudSyncCoordinator
) {
    guard !settings.didCompleteOnboarding else { return }
    let count = store.snapshot?.accounts.count ?? 0
    guard count == 0 else {
        // Existing user with accounts but legacy `didCompleteOnboarding`
        // unset — mark complete so they aren't surprised by a wizard.
        settings.didCompleteOnboarding = true
        return
    }
    OnboardingWindowController.shared.present(
        store: store,
        loginCoordinator: loginCoordinator,
        settings: settings,
        cloudSync: cloudSync
    )
}
