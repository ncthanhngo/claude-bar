import SwiftUI

/// Shared right-click / overflow menu items for an account row.
///
/// Rendered identically in Full (AccountRowView), Standard/Medium
/// (MediumAccountRow), and Tiny (TinyAccountRow) so the same actions —
/// connect/open/refresh/disconnect web usage, rename, switch, force
/// switch, remove — are reachable from every layout's right-click on an
/// account.
struct AccountActionMenu: View {
    let view: AccountViewDTO
    let onRename: () -> Void

    @EnvironmentObject var store: AppStore
    @EnvironmentObject var webFallback: WebFallbackCoordinator
    @EnvironmentObject var quickRelogin: QuickReloginCoordinator

    var body: some View {
        if webFallback.isLinked(view.account) {
            Button("Open web usage") { webFallback.open(for: view) }
            Button("Refresh web usage") { Task { await store.refreshNow() } }
            Button("Disconnect web usage", role: .destructive) {
                Task { await webFallback.disconnect(view.account) }
            }
        } else {
            Button("Connect web usage") { webFallback.open(for: view) }
        }
        Divider()
        Button("Quick re-login…") { quickRelogin.begin(for: view.account) }
        Button("Rename…", action: onRename)
        if !view.isActive {
            Button("Switch to this account") { trySwap() }
            Button("Force switch") { doSwap() }
            Divider()
            Button("Remove…", role: .destructive) {
                Task { await store.remove(view.account.number) }
            }
        }
    }

    private func trySwap() {
        guard !view.isActive else { return }
        if store.sessions?.safeToSwap == true { doSwap(); return }
        let sessions = RunningSession.readAll()
        if sessions.isEmpty { doSwap(); return }
        let alert = NSAlert()
        alert.messageText = "Claude is busy"
        let lines = sessions
            .map { "• \($0.typeLabel): \($0.locationLabel)" }
            .joined(separator: "\n")
        alert.informativeText = "Switching to \(view.account.displayName) may interrupt:\n\(lines)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force switch")
        alert.addButton(withTitle: "Cancel")
        if PopoverModal.runAlert(alert) == .alertFirstButtonReturn { doSwap() }
    }

    private func doSwap() {
        let num = view.account.number
        Task { @MainActor in await store.swap(to: num) }
    }
}
