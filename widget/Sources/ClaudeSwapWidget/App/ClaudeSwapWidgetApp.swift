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
    @StateObject private var cloudSync = CloudSyncCoordinator(client: CswClient())
    @StateObject private var localMCP = LocalMCPCoordinator(client: CswClient())
    @StateObject private var chatStore = ChatStore()
    @StateObject private var prefsCloudSync = PreferencesCloudSync.shared
    @StateObject private var updateController = UpdateController()
    @StateObject private var gateCoord = GateCoordinator()
    @ObservedObject private var settings = AppSettings.shared

    init() {
        // Diagnostics first so anything that crashes during the rest of init
        // (ClaudeWatchInstaller, settings migration, hotkey wiring) lands
        // in ~/Library/Logs/ClaudeBar/.
        DiagnosticsLogger.shared.bootstrap()
        CrashHandler.install()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        ClaudeWatchInstaller.install()
        migrateSettingsIfNeeded()
        syncReloadShortcutIfNeeded()

        // Capture refs to the @StateObject coordinators in a closure that
        // fires from AppDelegate.applicationDidFinishLaunching — independent
        // of whether MenuBarExtra ever opens its popover.
        let storeRef = _store.wrappedValue
        let loginRef = _loginCoordinator.wrappedValue
        let cloudRef = _cloudSync.wrappedValue
        let gateRef = _gateCoord.wrappedValue
        let settingsRef = AppSettings.shared
        AppDelegate.onLaunchCompleted = {
            Task { @MainActor in
                // Start the gate IPC proxy unconditionally at launch so MCP
                // write-tool prompts (Slack post, Sheets write, etc.) can
                // surface even when the user has never opened the popover.
                // Without this, MenuBarExtra's `.task` modifier defers the
                // start until first popover render, and every MCP write
                // call before that times out with `user_cancelled` (#11).
                gateRef.start()
                // Give store.start() (kicked off from the popover's .task)
                // a moment to fetch the snapshot. If the popover never opens,
                // snapshot stays nil — but `accounts.isEmpty` is still
                // computable as 0, so onboarding still fires correctly.
                try? await Task.sleep(nanoseconds: 800_000_000)
                presentOnboardingIfNeededAtLaunch(
                    store: storeRef,
                    loginCoordinator: loginRef,
                    settings: settingsRef,
                    cloudSync: cloudRef
                )
            }
        }
        _ = settingsRef
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
                .environmentObject(cloudSync)
                .environmentObject(localMCP)
                .environmentObject(updateController)
                .environmentObject(gateCoord)
                .task {
                    gateCoord.start()
                    loginCoordinator.attach(store: store)
                    verifyCoordinator.attach(store: store)
                    webFallback.attach(store: store)
                    store.cloudSync = cloudSync
                    store.start()
                    chatStore.bind(to: store)
                    // Wire environment for the standalone Settings window so
                    // its SwiftUI content sees the same coordinators the old
                    // in-popover SettingsTab received via the MenuBarExtra
                    // environment chain.
                    let storeBind = store
                    let loginBind = loginCoordinator
                    let verifyBind = verifyCoordinator
                    let webBind = webFallback
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
                                .environmentObject(cloudBind)
                                .environmentObject(mcpBind)
                                .environmentObject(updateBind)
                                .environmentObject(gateBind)
                        )
                    }
                    prefsCloudSync.start()
                    resetICloudSyncToggleOnVersionChange()
                    await cloudSync.refreshStatus()
                    await cloudSync.checkOnboarding(snapshot: store.snapshot)
                    presentOnboardingIfNeeded()
                    // Pre-warm the MCP coordinator off the main path so
                    // Settings → Local MCP is hot the first time the user
                    // opens it. Without this, the .task inside
                    // LocalMCPSettingsView fires on first open and the
                    // connector list inflates from a 1-line "Loading…"
                    // placeholder to ~5 connector rows AFTER first paint,
                    // shifting the page contents downward — the user
                    // perceives this as a "flash".
                    Task.detached(priority: .utility) { [localMCP] in
                        await localMCP.refresh()
                    }
                }
        } label: {
            MenuBarLabelView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }

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
