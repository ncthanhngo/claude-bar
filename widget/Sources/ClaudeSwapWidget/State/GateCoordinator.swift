import Foundation
import SwiftUI
import UserNotifications

/// Owns the long-lived gate IPC subprocess and surfaces pending prompts to
/// the UI. There is at most one pending prompt at a time — the MCP server's
/// AwaitApproval is synchronous, so a second prompt waits for the first to
/// resolve.
@MainActor
final class GateCoordinator: ObservableObject {
    /// Approval window matches the backend `GateService.Timeout` — keep them
    /// in lock-step. 60s gives the user time to spot the system notification,
    /// pull focus over to the popover, and read the args before deciding.
    static let approvalTimeoutSeconds = 60

    /// Currently pending prompt; nil when nothing awaiting user decision.
    @Published private(set) var pending: GatePromptDTO?

    /// Visible countdown (seconds) until auto-cancel. UI binds for the
    /// timer bar / chip animation.
    @Published private(set) var secondsRemaining: Int = GateCoordinator.approvalTimeoutSeconds

    /// True when the gate proxy subprocess is connected.
    @Published private(set) var isConnected: Bool = false

    /// Last error from the proxy subprocess (rare; surfaces in Diagnostics).
    @Published var lastError: String?

    private var reader: GateStreamReader?
    private var countdownTask: Task<Void, Never>?

    /// Starts the proxy subprocess. Called once at app launch.
    func start() {
        guard reader == nil else { return }
        let r = GateStreamReader(
            yield: { [weak self] ev in
                Task { @MainActor [weak self] in self?.handle(ev) }
            },
            onTermination: { [weak self] code, stderr in
                Task { @MainActor [weak self] in
                    self?.isConnected = false
                    if code != 0 && code != 130 {
                        self?.lastError = "gate proxy exited \(code): \(stderr)"
                    }
                }
            }
        )
        guard let r else {
            lastError = "csw binary not found"
            return
        }
        reader = r
        do {
            try r.start()
        } catch {
            lastError = "gate proxy spawn failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        reader?.stop()
        reader = nil
        isConnected = false
    }

    /// Approve the currently-pending prompt.
    func approve() {
        guard let p = pending, let r = reader else { return }
        r.respond(nonce: p.nonce, decision: .approved)
        clear()
    }

    /// Cancel the currently-pending prompt.
    func cancel() {
        guard let p = pending, let r = reader else { return }
        r.respond(nonce: p.nonce, decision: .cancelled)
        clear()
    }

    // MARK: - private

    private func handle(_ ev: GateStreamReader.Event) {
        switch ev {
        case .hello:
            isConnected = true
        case .prompt(let p):
            // If another prompt was pending (shouldn't happen — backend is
            // synchronous, one outstanding at a time), auto-cancel the old.
            if pending != nil { cancel() }
            pending = p
            startCountdown()
            surfacePrompt(p)
        }
    }

    /// Bring the user's attention to the new prompt. The overlay only lives
    /// inside the menu-bar popover, so when the user is focused on Claude
    /// Code the prompt would otherwise silently time out (issue #11). Two
    /// independent channels: (a) auto-open the popover ABOVE other Claude Bar
    /// windows (Settings, Daily) so the confirm UI is reachable with one
    /// keystroke even when those panels are open, (b) fire a time-sensitive
    /// banner notification that punches through Focus / DND modes.
    private func surfacePrompt(_ p: GatePromptDTO) {
        MenuBarPopoverToggle.openIfClosedAbove()
        postNotification(for: p)
    }

    private func postNotification(for p: GatePromptDTO) {
        let content = UNMutableNotificationContent()
        content.title = "Approval needed: \(p.tool)"
        content.body = p.summary.isEmpty ? AnyCodable.render(p.args) : p.summary
        content.sound = .default
        // Punch through Focus / Do Not Disturb — an MCP write tool is
        // blocking the LLM with a 60s deadline; missing the banner means
        // the call fails. The system still respects per-app overrides if
        // the user has explicitly muted Claude Bar.
        content.interruptionLevel = .timeSensitive
        // Same identifier per prompt so a fast retry replaces the prior
        // banner rather than stacking duplicates.
        let req = UNNotificationRequest(identifier: "csw.gate.\(p.nonce)", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(req) }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        let total = Self.approvalTimeoutSeconds
        secondsRemaining = total
        countdownTask = Task { [weak self] in
            for _ in 0..<total {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run {
                    if self.secondsRemaining > 0 { self.secondsRemaining -= 1 }
                }
            }
            // Timeout — the backend will also auto-cancel on its own
            // timer, but we send an explicit cancel for clean accounting.
            await MainActor.run { self?.cancel() }
        }
    }

    private func clear() {
        countdownTask?.cancel()
        countdownTask = nil
        pending = nil
        secondsRemaining = Self.approvalTimeoutSeconds
        clearNotificationsForCurrentPrompt()
    }

    private func clearNotificationsForCurrentPrompt() {
        // Best-effort: remove the banner once the user decided. Identifier
        // is unknown here (we just cleared pending), so wipe all gate banners.
        let center = UNUserNotificationCenter.current()
        Task {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix("csw.gate.") }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
            let pending = await center.pendingNotificationRequests()
            let pids = pending.map(\.identifier).filter { $0.hasPrefix("csw.gate.") }
            if !pids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pids) }
        }
    }
}
