import Foundation
import UserNotifications

/// Threshold-based auto-swap orchestrator.
///
/// Flow:
///   threshold reached → notify user → poll sessions every N sec →
///   when no busy/waiting session → swap → notify → return to IDLE.
///
/// Per spec: never kills claude processes (aggressiveAutoKill toggle reserved
/// for future use, not implemented in v1).
@MainActor
final class AutoSwapStateMachine: ObservableObject {
    enum State: Equatable {
        case idle
        case pendingSwap(toAccount: Int, reason: String, swapAt: Date)
        case cooldown(until: Date)
    }

    @Published private(set) var state: State = .idle

    var snapshotProvider: () -> ListAccountsDTO? = { nil }
    var sessionsProvider: () -> SessionReportDTO? = { nil }
    var onSwapPerformed: (() async -> Void)?

    private let client: CswClient
    private let settings: AppSettings
    private var task: Task<Void, Never>?

    /// Grace window between the user-facing "auto-swap pending" notification
    /// and the actual swap attempt. Gives users a chance to interrupt or wrap
    /// up an idle claude session before the account binding flips.
    private let swapGraceSec: TimeInterval = 60

    init(client: CswClient, settings: AppSettings) {
        self.client = client
        self.settings = settings
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() { task?.cancel() }

    private func loop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(settings.sessionPollIntervalSec) * 1_000_000_000)
            await tick()
        }
    }

    private func tick() async {
        guard settings.autoSwapEnabled else { state = .idle; return }
        if case .cooldown(let until) = state, Date() < until { return }

        guard let snap = snapshotProvider() else { return }
        guard let active = snap.active, let usage = active.usage else { return }

        // 5h quota only — that is the user-facing pacing signal.
        let activePct = usage.fiveHour?.percentInt ?? 0
        let threshold = settings.thresholdPct

        // Reset state if active account dropped below threshold (e.g. user
        // already swapped manually, or window reset).
        if activePct < threshold {
            if case .pendingSwap = state { state = .idle }
            return
        }

        // Find target with lowest 5h utilization among inactive accounts.
        let target = pickTarget(snap, threshold: threshold)
        guard let target else {
            await notifyAllExhausted()
            state = .cooldown(until: Date().addingTimeInterval(600))
            return
        }

        // Enter pendingSwap on first detection — arm the grace deadline and
        // notify the user once. Subsequent ticks reuse the same deadline.
        let swapAt: Date
        if case .pendingSwap(_, _, let existing) = state {
            swapAt = existing
        } else {
            swapAt = Date().addingTimeInterval(swapGraceSec)
            state = .pendingSwap(
                toAccount: target.account.number,
                reason: "active hit \(activePct)%",
                swapAt: swapAt
            )
            await notifyPending(to: target, activePct: activePct, inSec: Int(swapGraceSec))
        }

        // Wait out the grace window before attempting the swap.
        if Date() < swapAt { return }

        // Deadline reached — only swap if no claude session is running.
        guard let sess = sessionsProvider(), sess.safeToSwap else { return }

        do {
            try await client.switchTo(target.account.number)
            await notifySwapped(to: target)
            state = .cooldown(until: Date().addingTimeInterval(300))
            await onSwapPerformed?()
        } catch {
            state = .cooldown(until: Date().addingTimeInterval(60))
        }
    }

    private func pickTarget(_ snap: ListAccountsDTO, threshold: Int) -> AccountViewDTO? {
        snap.accounts
            .filter { !$0.isActive }
            .filter { ($0.usage?.fiveHour?.percentInt ?? 100) < threshold }
            .sorted { a, b in
                // 1. Higher subscription tier first (Max 200 > Max 100 > Pro > free)
                if a.subscriptionTier != b.subscriptionTier {
                    return a.subscriptionTier > b.subscriptionTier
                }
                // 2. Within same tier, most remaining quota (lowest % used)
                let pctA = a.usage?.fiveHour?.percentInt ?? 100
                let pctB = b.usage?.fiveHour?.percentInt ?? 100
                return pctA < pctB
            }
            .first
    }

    private func notifyPending(to target: AccountViewDTO, activePct: Int, inSec: Int) async {
        await postNotification(
            title: "Auto-swap in \(inSec)s (\(activePct)% used)",
            body: "Will switch to \(target.account.displayName) in \(inSec)s if no claude session is running.",
            id: "csw.pending"
        )
    }

    private func notifySwapped(to target: AccountViewDTO) async {
        await postNotification(
            title: "Switched to \(target.account.displayName)",
            body: "Restart claude to use the new account.",
            id: "csw.swapped"
        )
    }

    private func notifyAllExhausted() async {
        await postNotification(
            title: "All accounts above threshold",
            body: "No account available to swap to. Will retry in 10 minutes.",
            id: "csw.exhausted"
        )
    }

    private func postNotification(title: String, body: String, id: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}
