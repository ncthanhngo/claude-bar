import SwiftUI
import Carbon.HIToolbox
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
        // Fans left on Max/Custom by a crashed previous run go back to Auto.
        DispatchQueue.global(qos: .utility).async { FanControlStore.restoreAuto() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FanControlStore.restoreAuto()
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
    @StateObject private var updateController = UpdateController()
    @StateObject private var serverMonitor = ServerMonitorStore()
    @StateObject private var claudeStatus = ClaudeStatusStore()
    @StateObject private var systemMetrics = SystemMetricsStore()
    @ObservedObject private var settings = AppSettings.shared

    init() {
        // Diagnostics first so anything that crashes during the rest of init
        // (ClaudeWatchRemover, settings migration, hotkey wiring) lands
        // in ~/Library/Logs/ClaudeBar/.
        DiagnosticsLogger.shared.bootstrap()
        CrashHandler.install()
        // Export CLAUDE_BIN so csw children can find the Claude
        // CLI even under the GUI's minimal PATH (Finder-launched apps don't
        // inherit the shell PATH where claude is installed).
        ClaudeBinaryEnv.ensure()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        ClaudeWatchRemover.run()
        CbarShortcutInstaller.install()
        CmuxConfigInstaller.install()
        migrateSettingsIfNeeded()
        syncReloadShortcutIfNeeded()

        // Coordinators get wired from MenuBarLabelView.onAppear — see
        // `wireCoordinatorsOnce` for the reasoning around @StateObject
        // identity in App.init().
        AppDelegate.onLaunchCompleted = {
            Task { @MainActor in
                DiagnosticsLogger.shared.log(.info, subsystem: "launch", "AppDelegate didFinishLaunching")
                // ⌥Z toggles the popover. Must run at launch (not from the
                // popover's .task) so the hotkey works on a cold-launched
                // session the user hasn't clicked into yet.
                Self.registerGlobalHotkey(settings: AppSettings.shared)
            }
        }
    }

    /// Wire the global Carbon hotkeys: ⌥Z popover toggle, ⌥X away mode.
    @MainActor
    static func registerGlobalHotkey(settings: AppSettings) {
        HotkeyRegistry.shared.register(
            name: HotkeySlot.openApp,
            keyCode: UInt32(settings.briefingHotkeyOpenAppKeyCode),
            modifiers: UInt32(settings.briefingHotkeyOpenAppModifiers)
        ) {
            MenuBarPopoverToggle.toggle()
        }
        HotkeyRegistry.shared.register(
            name: HotkeySlot.awayMode,
            keyCode: UInt32(kVK_ANSI_X),
            modifiers: UInt32(optionKey)
        ) {
            AwayModeController.shared.start()
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
                "autoReloadIDEAfterSwap", "autoSwapEnabled",
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
                .environmentObject(updateController)
                .environmentObject(serverMonitor)
                .environmentObject(claudeStatus)
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
                .environmentObject(serverMonitor)
                .environmentObject(claudeStatus)
                .environmentObject(systemMetrics)
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
        DiagnosticsLogger.shared.log(.info, subsystem: "launch", "coordinators wired")
        // All periodic loops (usage polling, web keep-alive)
        // are driven through one switch so a persisted
        // pause survives relaunch and the Settings toggle can flip the whole
        // app dormant. `apply` either starts everything or leaves it stopped
        // depending on the saved flag.
        BackgroundWorkController.shared.register(
            store: store,
            webFallback: webFallback,
            serverMonitor: serverMonitor,
            claudeStatus: claudeStatus,
            systemMetrics: systemMetrics
        )
        BackgroundWorkController.shared.apply(dormant: settings.dormantModeEnabled)
        DiagnosticsLogger.shared.log(.info, subsystem: "launch", "polling started")
        let storeBind = store
        let loginBind = loginCoordinator
        let verifyBind = verifyCoordinator
        let webBind = webFallback
        let quickBind = quickRelogin
        let updateBind = updateController
        SettingsWindowController.shared.bindEnvironment { content in
            AnyView(
                content
                    .environmentObject(storeBind)
                    .environmentObject(loginBind)
                    .environmentObject(verifyBind)
                    .environmentObject(webBind)
                    .environmentObject(quickBind)
                    .environmentObject(updateBind)
            )
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            presentOnboardingIfNeeded()
            DiagnosticsLogger.shared.log(.info, subsystem: "launch", "end wireCoordinatorsOnce")
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
            settings: settings
        )
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
    settings: AppSettings
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
        settings: settings
    )
}
