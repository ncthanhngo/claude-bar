import Foundation
import UserNotifications

/// Threshold-based auto-swap orchestrator.
///
/// Flow:
///   threshold reached → notify user with 60s grace → after grace,
///   swap → notify → return to IDLE.
///
/// The grace window is a soft warning, not a hard gate. Pre-#18 the swap
/// also waited for `safeToSwap` (no live claude session) after the grace,
/// which silently disabled auto-swap for anyone keeping a claude session
/// running. Now: notify, wait the grace, swap regardless. Auto-swap does
/// not kill claude — the existing process keeps its cached tokens; the
/// next invocation picks up the new account. Users who want the live
/// process restarted can enable `autoKillCLIAfterSwap` (post-swap SIGINT).
@MainActor
final class AutoSwapStateMachine: ObservableObject {
    enum State: Equatable {
        case idle
        case pendingSwap(toAccount: Int, reason: String, swapAt: Date)
        case cooldown(until: Date)
    }

    @Published private(set) var state: State = .idle

    var snapshotProvider: () -> ListAccountsDTO? = { nil }
    var onSwapPerformed: (() async -> Void)?

    /// Drives credential recovery bookkeeping (cooldown, retry cap, single
    /// flight, outcome handling). The state machine is the SOLE driver of
    /// recovery — both the active branch here and the inactive sweep route
    /// through this coordinator so there is never a second competing loop.
    weak var recovery: CredentialRecoveryCoordinator?

    /// Reports whether an interactive re-login sheet is currently on screen.
    /// When true the credential branch stands down — the user is already
    /// resolving the credential by hand and we must not swap or relogin under
    /// them. Injected so the state machine has no direct WebKit dependency.
    var isInteractiveReloginActive: () -> Bool = { false }

    // Accessed by the credential-recovery extension (separate file), so these
    // are module-internal rather than private.
    let client: CswClient
    let settings: AppSettings
    private var task: Task<Void, Never>?

    // MARK: - Credential recovery state (Phase 3)

    /// Pending credential-recovery action, kept SEPARATE from the quota `state`
    /// enum on purpose: routing credential cooldown through `state` would let a
    /// credential failure short-circuit the whole tick and freeze quota swap.
    enum CredAction: Equatable {
        case idle
        /// A healthy target was found; swap to it once the grace expires.
        case pendingSwap(target: Int, swapAt: Date)
        /// No healthy target; re-login the active account in place after grace.
        case pendingRelogin(swapAt: Date)
    }
    // Accessed by the credential-recovery extension (separate file).
    var credAction: CredAction = .idle

    /// Per-account count of consecutive definitive `needs_login` polls for the
    /// ACTIVE slot. Debounces transient blips: recovery only fires once the
    /// count crosses `credFailureThreshold`. Reset to 0 on any non-definitive
    /// poll (healthy, transient error, or unknown).
    var consecutiveCredFailures: [Int: Int] = [:]

    /// Consecutive definitive failures required before acting. A single blip
    /// must never trigger recovery; N in a row is the signal.
    let credFailureThreshold = 2

    /// Grace between the "swapping to recover" notification and the swap.
    /// Shorter than the 60s quota grace (user-confirmed) — recovery is urgent;
    /// the Cancel notification action (Phase 7) is the safety valve.
    let credSwapDelaySec: TimeInterval = 3
    /// Grace before a hidden in-place re-login when no swap target exists.
    let credReloginDelaySec: TimeInterval = 7

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
        // Credential recovery runs FIRST and independently of quota auto-swap.
        // If it performed a swap/relogin this tick, skip the quota pass so we
        // don't double-act on a snapshot that is about to be refreshed.
        if await handleCredentialRecovery() { return }
        await handleQuotaSwap()
    }

    private func handleQuotaSwap() async {
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

        // Deadline reached — swap regardless of live claude sessions. The
        // grace already warned the user; further blocking would silently
        // disable auto-swap for anyone running claude continuously.
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
            body: "Will switch to \(target.account.displayName) in \(inSec)s. Close claude now if you want it to finish cleanly first.",
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

    func postNotification(title: String, body: String, id: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}
