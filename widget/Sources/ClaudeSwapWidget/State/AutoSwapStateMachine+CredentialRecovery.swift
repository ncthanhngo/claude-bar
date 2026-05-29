import Foundation
import UserNotifications

/// Credential auto-recovery branch of the auto-swap loop.
///
/// Split into its own file to keep `AutoSwapStateMachine` lean: the stored
/// state (`credAction`, `consecutiveCredFailures`, `recovery`) lives in the
/// main type; the orchestration lives here. The state machine is the single
/// driver of all recovery — the active branch below, plus a non-blocking
/// sweep of inactive accounts — so two competing loops can never race.
///
/// Flow when the ACTIVE credential is definitively dead for N consecutive
/// polls (debounced via `consecutiveCredFailures`):
///   - healthy target available → notify, swap after `credSwapDelaySec`, then
///     the now-inactive broken account is silently repaired by the sweep.
///   - no target → notify, hidden in-place re-login after `credReloginDelaySec`.
///
/// All cooldown / retry-cap / single-flight bookkeeping is delegated to
/// `CredentialRecoveryCoordinator`; this branch only decides swap-vs-relogin
/// and owns the grace-window timing.
@MainActor
extension AutoSwapStateMachine {

    /// Returns true if a credential-recovery action was performed (or is mid
    /// grace) this tick, signalling the caller to skip the quota pass.
    func handleCredentialRecovery() async -> Bool {
        guard settings.autoRecoverEnabled else { credAction = .idle; return false }
        guard let snap = snapshotProvider() else { return false }

        // Always sweep inactive accounts for needs_login — non-blocking so a
        // 30s headless attempt never stalls the poll loop. The coordinator's
        // single-flight makes repeated calls idempotent.
        driveInactiveRecovery(snap)

        // No active account in the snapshot → leave the counter untouched and
        // do not act (the tick early-returns elsewhere when active is absent).
        guard let active = snap.active else { return false }
        let num = active.account.number

        // Debounce transition rules. Only a FRESH definitive needs_login (no
        // transient usage error masking it) counts. Anything else — healthy
        // ("ready"), a transient error, or unknown — resets the streak so a
        // single blip can never accumulate toward a false recovery.
        if active.error == nil && active.credentialState == "needs_login" {
            consecutiveCredFailures[num, default: 0] += 1
        } else {
            consecutiveCredFailures[num] = 0
            credAction = .idle
            return false
        }

        guard (consecutiveCredFailures[num] ?? 0) >= credFailureThreshold else {
            return false
        }

        // Stand down while the user is resolving it by hand.
        if isInteractiveReloginActive() { credAction = .idle; return false }

        // Let the coordinator own this account if it is already recovering it,
        // cooling down, or terminal (needs manual sign-in). Prevents spamming
        // attempts and hands terminal states to Phase 4.
        if let rec = recovery, !rec.isEligible(num) {
            credAction = .idle
            return false
        }

        return await driveActiveRecovery(num, snapshot: snap)
    }

    // MARK: - Active recovery

    /// Arms the grace window on first detection, then performs the chosen
    /// action once the grace expires. Returns true whenever the branch is in
    /// charge of this tick (armed-and-waiting or acting).
    private func driveActiveRecovery(_ activeNum: Int, snapshot snap: ListAccountsDTO) async -> Bool {
        switch credAction {
        case .idle:
            // First confirmed detection — arm the grace and notify once.
            if let target = pickHealthyTarget(snap) {
                credAction = .pendingSwap(target: target.account.number,
                                          swapAt: Date().addingTimeInterval(credSwapDelaySec))
                await notifyCredSwapPending(to: target, inSec: Int(credSwapDelaySec))
            } else {
                credAction = .pendingRelogin(swapAt: Date().addingTimeInterval(credReloginDelaySec))
                await notifyCredReloginPending(inSec: Int(credReloginDelaySec))
            }
            return true

        case .pendingSwap(_, let swapAt):
            if Date() < swapAt { return true }   // still in grace
            await performRecoverySwap(brokenActive: activeNum)
            return true

        case .pendingRelogin(let swapAt):
            if Date() < swapAt { return true }   // still in grace
            await performInPlaceRelogin(activeNum)
            return true
        }
    }

    /// Re-validates a healthy target against the CURRENT snapshot (a target can
    /// die during the grace) and swaps to it. The broken account — now inactive
    /// after the swap — is repaired by the inactive sweep on a later tick.
    /// Falls back to in-place re-login if every target died during the grace.
    private func performRecoverySwap(brokenActive: Int) async {
        guard let snap = snapshotProvider() else { credAction = .idle; return }
        guard let target = pickHealthyTarget(snap) else {
            // All targets died during grace — re-arm as in-place re-login.
            credAction = .pendingRelogin(swapAt: Date().addingTimeInterval(credReloginDelaySec))
            await notifyCredReloginPending(inSec: Int(credReloginDelaySec))
            return
        }
        do {
            try await client.switchTo(target.account.number)
            consecutiveCredFailures[brokenActive] = 0
            credAction = .idle
            await notifyCredSwapped(to: target)
            // Post-swap integrations + refreshNow. The refreshed snapshot shows
            // the broken account as inactive+needs_login; the next tick's sweep
            // repairs it silently.
            await onSwapPerformed?()
        } catch {
            // Swap failed — leave credAction idle so the next confirmed poll
            // re-arms. Do not reset the failure streak (the credential is still
            // dead); a fresh detection will retry.
            credAction = .idle
        }
    }

    /// Hidden in-place re-login of the active account via the recovery
    /// coordinator (single-flight, cooldown and retry-cap handled there).
    private func performInPlaceRelogin(_ activeNum: Int) async {
        credAction = .idle
        consecutiveCredFailures[activeNum] = 0
        guard let rec = recovery else { return }
        let outcome = await rec.recover(accountNum: activeNum)
        switch outcome {
        case .succeeded:
            await notifyCredRecovered()
        default:
            // failure / terminal / busy: the coordinator owns cooldown + the
            // needsManualSignIn terminal state (surfaced by Phase 4). No notify
            // here to avoid spamming on a transient retry.
            break
        }
    }

    /// Fire-and-forget sweep of inactive accounts flagged needs_login. The
    /// coordinator's single-flight guard makes this safe to call every tick.
    private func driveInactiveRecovery(_ snap: ListAccountsDTO) {
        guard let rec = recovery else { return }
        Task { await rec.recoverInactiveIfNeeded(snap) }
    }

    // MARK: - Target selection

    /// Picks the best HEALTHY inactive account to swap onto during recovery.
    /// Unlike the quota picker this ignores the usage threshold (any healthy
    /// account beats a dead one) but excludes accounts flagged needs_login.
    /// `credentialState == nil` is treated as healthy: it is only populated on
    /// usage/live-probe snapshots and is frequently nil on web-usage rows —
    /// filtering it out would reject every otherwise-healthy target.
    func pickHealthyTarget(_ snap: ListAccountsDTO) -> AccountViewDTO? {
        snap.accounts
            .filter { !$0.isActive }
            .filter { $0.credentialState != "needs_login" }
            .sorted { a, b in
                // Higher subscription tier first, then most remaining quota.
                if a.subscriptionTier != b.subscriptionTier {
                    return a.subscriptionTier > b.subscriptionTier
                }
                let pctA = a.usage?.fiveHour?.percentInt ?? 100
                let pctB = b.usage?.fiveHour?.percentInt ?? 100
                return pctA < pctB
            }
            .first
    }

    // MARK: - Notifications

    private func notifyCredSwapPending(to target: AccountViewDTO, inSec: Int) async {
        await postNotification(
            title: "Re-login needed — swapping in \(inSec)s",
            body: "Active account credential expired. Switching to \(target.account.displayName) and repairing it in the background.",
            id: "csw.cred.swap"
        )
    }

    private func notifyCredReloginPending(inSec: Int) async {
        await postNotification(
            title: "Re-login needed — recovering in \(inSec)s",
            body: "Active account credential expired. Signing back in automatically.",
            id: "csw.cred.relogin"
        )
    }

    private func notifyCredSwapped(to target: AccountViewDTO) async {
        await postNotification(
            title: "Recovered — switched to \(target.account.displayName)",
            body: "Restart claude to use the new account. The expired account is being repaired.",
            id: "csw.cred.swapped"
        )
    }

    private func notifyCredRecovered() async {
        await postNotification(
            title: "Re-login complete",
            body: "Your active account credential was restored automatically.",
            id: "csw.cred.recovered"
        )
    }
}
