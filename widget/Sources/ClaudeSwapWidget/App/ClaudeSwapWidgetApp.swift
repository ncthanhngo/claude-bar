import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // menu bar app — never quit just because a window closed
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("claudebar.openSettings")
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
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        ClaudeWatchInstaller.install()
        migrateSettingsIfNeeded()
        syncReloadShortcutIfNeeded()
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
            MenuContentView()
                .environmentObject(store)
                .environmentObject(loginCoordinator)
                .environmentObject(verifyCoordinator)
                .environmentObject(webFallback)
                .environmentObject(cloudSync)
                .environmentObject(briefingCoord)
                .frame(width: 400)
                .task {
                    loginCoordinator.attach(store: store)
                    verifyCoordinator.attach(store: store)
                    webFallback.attach(store: store)
                    store.cloudSync = cloudSync
                    store.start()
                    briefingCoord.start()
                    BriefingWindowController.shared.attach(coordinator: briefingCoord)
                    BriefingHotkey.shared.register(
                        keyCode: BriefingHotkeyDefault.keyCode,
                        modifiers: BriefingHotkeyDefault.modifiers
                    ) {
                        Task { @MainActor in briefingCoord.show() }
                    }
                    await cloudSync.refreshStatus()
                    await cloudSync.checkOnboarding(snapshot: store.snapshot)
                }
                .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                    openSettings()
                    let abovePopup = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows
                            .filter { $0.isVisible && $0.canBecomeKey }
                            .filter { $0.level == .normal }
                            .forEach { win in
                                win.level = abovePopup
                                win.makeKeyAndOrderFront(nil)
                            }
                    }
                }
        } label: {
            MenuBarLabelView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowView()
                .environmentObject(store)
                .environmentObject(loginCoordinator)
                .environmentObject(verifyCoordinator)
                .environmentObject(webFallback)
                .environmentObject(cloudSync)
                .environmentObject(localMCP)
                .environmentObject(briefingCoord)
        }
    }
}
