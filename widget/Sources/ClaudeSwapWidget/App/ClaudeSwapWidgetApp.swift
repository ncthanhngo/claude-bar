import SwiftUI
import UserNotifications

extension Notification.Name {
    static let openSettings = Notification.Name("claudebar.openSettings")
}

@main
struct ClaudeSwapWidgetApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var loginCoordinator = LoginCoordinator()
    @StateObject private var verifyCoordinator = VerifyCoordinator()
    @StateObject private var webFallback = WebFallbackCoordinator()
    @StateObject private var cloudSync = CloudSyncCoordinator(client: CswClient())
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        ClaudeWatchInstaller.install()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                .environmentObject(loginCoordinator)
                .environmentObject(verifyCoordinator)
                .environmentObject(webFallback)
                .environmentObject(cloudSync)
                .frame(width: 400)
                .task {
                    loginCoordinator.attach(store: store)
                    verifyCoordinator.attach(store: store)
                    webFallback.attach(store: store)
                    store.cloudSync = cloudSync
                    store.start()
                    await cloudSync.refreshStatus()
                    await cloudSync.checkOnboarding(snapshot: store.snapshot)
                }
                .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                    // Dismiss the popover: grab all visible windows now (only the popover
                    // is open at this moment), capture frame, then hide them all.
                    NSApp.windows.filter { $0.isVisible }.forEach { $0.orderOut(nil) }
                    openSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows
                            .filter { $0.isVisible && $0.canBecomeKey }
                            .filter { $0.level == .normal }
                            .forEach { win in
                                win.center()
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
        }
    }
}
