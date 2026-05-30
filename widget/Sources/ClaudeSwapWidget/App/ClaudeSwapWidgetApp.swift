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
        // (ClaudeWatchInstaller, settings migration, hotkey wiring) lands
        // in ~/Library/Logs/ClaudeBar/.
        DiagnosticsLogger.shared.bootstrap()
        CrashHandler.install()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        ClaudeWatchInstaller.install()
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

        // Capture refs to every @StateObject the launch-time wiring needs.
        // MenuBarExtra's `.task` is lazy — fires only on first popover render
        // — so wiring that lives there is invisible to background work after
        // a Sparkle restart until the user manually opens the menu. Lifting
        // the full setup into AppDelegate.applicationDidFinishLaunching means
        // the polling loop, notification handler, and recovery plumbing all
        // come up at process start, matching what users expect from a
        // menu-bar app.
        let storeRef = _store.wrappedValue
        let loginRef = _loginCoordinator.wrappedValue
        let verifyRef = _verifyCoordinator.wrappedValue
        let webRef = _webFallback.wrappedValue
        let quickRef = _quickRelogin.wrappedValue
        let recoveryRef = _recovery.wrappedValue
        let cloudRef = _cloudSync.wrappedValue
        let mcpRef = _localMCP.wrappedValue
        let chatRef = _chatStore.wrappedValue
        let prefsRef = _prefsCloudSync.wrappedValue
        let updateRef = _updateController.wrappedValue
        let gateRef = _gateCoord.wrappedValue
        let settingsRef = AppSettings.shared
        AppDelegate.onLaunchCompleted = {
            Task { @MainActor in
                DiagnosticsLogger.shared.log(.info, subsystem: "launch", "begin onLaunchCompleted")
                // Start the gate IPC proxy unconditionally at launch so MCP
                // write-tool prompts (Slack post, Sheets write, etc.) can
                // surface even when the user has never opened the popover.
                gateRef.start()
                // Coordinator wire-up — order matches the previous in-popover
                // sequence so cross-coordinator weak references settle before
                // anyone is asked to do real work.
                loginRef.attach(store: storeRef)
                verifyRef.attach(store: storeRef)
                webRef.attach(store: storeRef)
                quickRef.attach(store: storeRef, webFallback: webRef, loginCoordinator: loginRef)
                loginRef.quickRelogin = quickRef
                recoveryRef.headlessRelogin = { [weak quickRef] accountNum in
                    await quickRef?.beginHeadless(forAccountNumber: accountNum)
                        ?? .failed("no coordinator")
                }
                storeRef.recovery = recoveryRef
                let notifHandler = NotificationActionHandler(autoSwap: storeRef.autoSwap)
                notifHandler.install()
                storeRef.notificationHandler = notifHandler
                storeRef.autoSwap.recovery = recoveryRef
                storeRef.autoSwap.isInteractiveReloginActive = { [weak quickRef] in
                    quickRef?.isPresentingInteractive ?? false
                }
                storeRef.cloudSync = cloudRef
                DiagnosticsLogger.shared.log(.info, subsystem: "launch", "coordinators wired")
                // Kick the polling timer + auto-swap loop. Previously deferred
                // to first popover open, which broke auto-swap and token
                // refresh after a Sparkle restart.
                storeRef.start()
                chatRef.bind(to: storeRef)
                DiagnosticsLogger.shared.log(.info, subsystem: "launch", "polling started")
                // Standalone Settings window inherits the same coordinators
                // the popover would have injected via environment.
                SettingsWindowController.shared.bindEnvironment { content in
                    AnyView(
                        content
                            .environmentObject(storeRef)
                            .environmentObject(loginRef)
                            .environmentObject(verifyRef)
                            .environmentObject(webRef)
                            .environmentObject(quickRef)
                            .environmentObject(cloudRef)
                            .environmentObject(mcpRef)
                            .environmentObject(updateRef)
                            .environmentObject(gateRef)
                    )
                }
                prefsRef.start()
                await cloudRef.refreshStatus()
                await cloudRef.checkOnboarding(snapshot: storeRef.snapshot)
                DiagnosticsLogger.shared.log(.info, subsystem: "launch", "cloud sync ready (enabled=\(settingsRef.iCloudSyncEnabled))")
                // Give the first refresh cycle a moment so onboarding sees
                // the real account count instead of nil — matches prior
                // behaviour where popover render ran the same await chain
                // before this 800ms gap.
                try? await Task.sleep(nanoseconds: 800_000_000)
                presentOnboardingIfNeededAtLaunch(
                    store: storeRef,
                    loginCoordinator: loginRef,
                    settings: settingsRef,
                    cloudSync: cloudRef
                )
                // Pre-warm MCP off the main path so Settings → Local MCP is
                // hot on first open, no late-inflate flash.
                Task.detached(priority: .utility) { [mcpRef] in
                    await mcpRef.refresh()
                }
                DiagnosticsLogger.shared.log(.info, subsystem: "launch", "end onLaunchCompleted")
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
