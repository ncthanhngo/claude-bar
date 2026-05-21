import Foundation
import SwiftUI
import AppKit

/// Drives the multi-step "Add account" flow.
///
/// Wizard lives in a separate floating NSWindow (not a MenuBarExtra sheet)
/// so it survives the user switching focus to Terminal or the browser.
@MainActor
final class LoginCoordinator: ObservableObject {
    enum Step: Equatable {
        case intro
        case terminalSpawned
        case snapshotting
        case done(displayName: String, wasDuplicate: Bool, duplicateOf: Int?)
        case failed(String)
    }

    @Published var step: Step = .intro
    @Published var pendingNickname: String = ""

    private let window = FloatingWindow<AnyView>()
    private weak var store: AppStore?

    func attach(store: AppStore) { self.store = store }

    /// Open the floating Add-account window.
    func begin() {
        step = .intro
        pendingNickname = ""
        guard let store else { return }
        window.show(title: "Add Claude account", size: NSSize(width: 460, height: 360)) {
            AnyView(
                AddAccountSheet()
                    .environmentObject(store)
                    .environmentObject(self)
            )
        }
    }

    func spawnTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "echo '👉 Run: claude'; echo '   then /login and complete the browser flow.'; echo '   Return to the widget and click \\"I’m logged in\\".'; exec $SHELL -l"
        end tell
        """
        runOsaScript(script)
        step = .terminalSpawned
    }

    func performSnapshot(client: CswClient) async {
        step = .snapshotting
        do {
            let res = try await client.add(
                nickname: pendingNickname.isEmpty ? nil : pendingNickname
            )
            await store?.refreshNow()
            step = .done(
                displayName: res.account.displayName,
                wasDuplicate: res.wasDuplicate,
                duplicateOf: res.duplicateOfNum
            )
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    func dismiss() {
        window.close()
        step = .intro
    }

    private func runOsaScript(_ src: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", src]
        try? task.run()
    }
}
