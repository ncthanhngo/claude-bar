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
    @StateObject private var briefingCoord = BriefingCoordinator(client: CswClient())
    @StateObject private var chatStore = ChatStore()
    @StateObject private var newsCoord = NewsFeedCoordinator()
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
        let settingsRef = AppSettings.shared
        AppDelegate.onLaunchCompleted = {
            Task { @MainActor in
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
    }

    @MainActor
    private func registerBriefingHotkeys(briefing: BriefingCoordinator) {
        let s = AppSettings.shared
        // ⌥Z by default — toggles the menu bar popover (xổ xuống / thu lên).
        HotkeyRegistry.shared.register(
            name: BriefingHotkeySlot.openApp,
            keyCode: UInt32(s.briefingHotkeyOpenAppKeyCode),
            modifiers: UInt32(s.briefingHotkeyOpenAppModifiers)
        ) {
            MenuBarPopoverToggle.toggle()
        }
        // ⌥X by default — toggles the Daily Briefing window.
        HotkeyRegistry.shared.register(
            name: BriefingHotkeySlot.openBriefing,
            keyCode: UInt32(s.briefingHotkeyOpenBriefingKeyCode),
            modifiers: UInt32(s.briefingHotkeyOpenBriefingModifiers)
        ) {
            briefing.toggle()
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
            WidgetTabbedPopover()
                .environmentObject(store)
                .environmentObject(loginCoordinator)
                .environmentObject(verifyCoordinator)
                .environmentObject(webFallback)
                .environmentObject(cloudSync)
                .environmentObject(briefingCoord)
                .environmentObject(localMCP)
                .environmentObject(updateController)
                .environmentObject(gateCoord)
                // Destructive write-gate modal. `isPresented` binding is
                // settable both ways — the previous `set: { _ in }` no-op
                // left SwiftUI thinking a sheet was "in-flight" forever,
                // which kept the popover modal-locked and broke the MCP
                // tab's Connect sheet auto-dismiss.
                .sheet(isPresented: Binding(
                    get: { gateCoord.pending?.risk == .destructive },
                    set: { isOpen in if !isOpen { gateCoord.cancel() } }
                )) {
                    ConfirmGateModal(gate: gateCoord)
                }
                .task {
                    gateCoord.start()
                    loginCoordinator.attach(store: store)
                    verifyCoordinator.attach(store: store)
                    webFallback.attach(store: store)
                    store.cloudSync = cloudSync
                    store.start()
                    briefingCoord.start()
                    chatStore.bind(to: store)
                    newsCoord.start()
                    BriefingWindowController.shared.attach(
                        coordinator: briefingCoord,
                        store: store,
                        chatStore: chatStore,
                        newsCoord: newsCoord
                    )
                    registerBriefingHotkeys(briefing: briefingCoord)
                    prefsCloudSync.start()
                    await cloudSync.refreshStatus()
                    await cloudSync.checkOnboarding(snapshot: store.snapshot)
                    presentOnboardingIfNeeded()
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
