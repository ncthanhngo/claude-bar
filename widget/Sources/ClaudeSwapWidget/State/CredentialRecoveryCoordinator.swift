import Foundation

/// Phase of a single account's credential recovery lifecycle.
enum RecoveryPhase {
    /// No recovery in progress or needed.
    case idle
    /// Recovery queued but not yet started (e.g. waiting for single-flight).
    case pending
    /// Headless re-login is actively running for this account.
    case recovering
    /// A login form was detected — only interactive re-login can resolve this.
    /// Terminal until the user completes interactive flow and resets status.
    case needsManualSignIn
    /// Recovery failed; cooldown period is active before the next attempt.
    case cooldown
}

/// Snapshot of recovery state for one account number.
struct RecoveryStatus {
    var phase: RecoveryPhase = .idle
    var attempts: Int = 0
    var lastAttemptAt: Date?
    var cooldownUntil: Date?
}

/// Owns and drives silent credential recovery for inactive accounts.
///
/// This coordinator holds the `[Int: RecoveryStatus]` map — AppStore is not
/// the right home because recovery state is orthogonal to usage/snapshot state
/// and AppStore is already large. Phase 3 calls `recoverInactiveIfNeeded` from
/// the AutoSwapStateMachine tick; this coordinator enforces the retry cap,
/// cooldown, and single-flight so the state machine does not need to.
///
/// The headless re-login itself is injected as `headlessRelogin` so this type
/// has no direct dependency on `QuickReloginCoordinator` — the wiring lives
/// in `ClaudeSwapWidgetApp` where both coordinators are in scope.
@MainActor
final class CredentialRecoveryCoordinator: ObservableObject {

    // MARK: - Configuration

    /// Maximum attempts before the account is moved to `.needsManualSignIn`
    /// terminal state (no further automatic retries).
    private static let maxAttempts = 3

    /// Cooldown between retry attempts after a transient failure.
    private static let cooldownInterval: TimeInterval = 5 * 60  // 5 minutes

    // MARK: - Published state

    @Published private(set) var statuses: [Int: RecoveryStatus] = [:]

    // MARK: - Injected dependencies

    /// Set by the app wiring once both coordinators exist. The closure
    /// captures a weak reference to `QuickReloginCoordinator` so this
    /// coordinator does not create a retain cycle with the app graph.
    var headlessRelogin: ((Int) async -> ReloginOutcome)?

    // MARK: - Single-flight guard

    /// True while a headless recovery is actively running. Prevents a second
    /// concurrent recovery from starting if `recoverInactiveIfNeeded` is
    /// called again before the first finishes (e.g. two rapid state-machine
    /// ticks). Only one headless attempt runs at a time across all accounts.
    private var recoveryInFlight = false

    // MARK: - Computed helpers

    /// True while a headless attempt is actively running for `accountNum`.
    func isRecovering(_ accountNum: Int) -> Bool {
        statuses[accountNum]?.phase == .recovering
    }

    /// True when the account has reached a terminal state requiring the user
    /// to sign in interactively (dead session cookies or identity mismatch).
    func manualSignInRequired(_ accountNum: Int) -> Bool {
        statuses[accountNum]?.phase == .needsManualSignIn
    }

    // MARK: - Recovery entry point

    /// Finds the first inactive account whose `credentialState == "needs_login"`
    /// and is eligible for a headless recovery attempt, then runs it.
    ///
    /// Eligibility rules (all must pass):
    ///   - Not currently recovering or in needsManualSignIn terminal state.
    ///   - Not in active cooldown.
    ///   - Attempt count has not reached the cap (3).
    ///
    /// Only one recovery runs at a time: if a recovery is already in flight
    /// this call returns immediately. Phase 3 is responsible for calling this
    /// at the right cadence; no internal poll loop is started here.
    func recoverInactiveIfNeeded(_ snapshot: ListAccountsDTO) async {
        guard !recoveryInFlight else { return }

        let now = Date()
        // Find the first eligible inactive account with needs_login.
        guard let target = snapshot.accounts.first(where: { view in
            guard !view.isActive,
                  view.credentialState == "needs_login" else { return false }
            let status = statuses[view.account.number] ?? RecoveryStatus()
            switch status.phase {
            case .needsManualSignIn: return false   // terminal — user must act
            case .recovering, .pending: return false // already in flight
            case .cooldown:
                // Respect the cooldown window.
                if let until = status.cooldownUntil, now < until { return false }
                return true
            case .idle:
                return status.attempts < Self.maxAttempts
            }
        }) else { return }

        let accountNum = target.account.number
        recoveryInFlight = true
        // Exception-safe: a future throwing/cancelled headlessRelogin must not
        // leave this stuck true, which would wedge all recovery permanently.
        defer { recoveryInFlight = false }
        setPhase(.recovering, for: accountNum)

        DiagnosticsLogger.shared.log(.info, subsystem: "credential-recovery",
            "starting headless recovery account=\(accountNum) attempts=\(statuses[accountNum]?.attempts ?? 0)")

        guard let fn = headlessRelogin else {
            // No attempt actually ran — don't burn the retry budget. Revert to
            // idle so the next tick re-evaluates once wiring is present.
            setPhase(.idle, for: accountNum)
            return
        }
        let outcome = await fn(accountNum)

        // A "busy" outcome means another attempt held the single-flight lock —
        // no real auth happened, so don't count it toward the retry cap.
        if case .failed("busy") = outcome {
            setPhase(.idle, for: accountNum)
            return
        }
        applyOutcome(outcome, for: accountNum)
    }

    // MARK: - Outcome application

    private func applyOutcome(_ outcome: ReloginOutcome, for accountNum: Int) {
        var status = statuses[accountNum] ?? RecoveryStatus()
        status.lastAttemptAt = Date()

        switch outcome {
        case .succeeded:
            // Clear all recovery state — the credential is healthy again.
            DiagnosticsLogger.shared.log(.info, subsystem: "credential-recovery",
                "recovery succeeded account=\(accountNum)")
            statuses[accountNum] = nil

        case .failed(let reason):
            status.attempts += 1
            DiagnosticsLogger.shared.log(.warning, subsystem: "credential-recovery",
                "recovery failed account=\(accountNum) attempts=\(status.attempts) reason=\(reason)")
            if status.attempts >= Self.maxAttempts {
                // Cap reached — require manual sign-in.
                status.phase = .needsManualSignIn
            } else {
                // Transient failure — enter cooldown before retrying.
                status.phase = .cooldown
                status.cooldownUntil = Date().addingTimeInterval(Self.cooldownInterval)
            }
            statuses[accountNum] = status

        case .needsManualSignIn:
            // Positive login-form detection: terminal, no retry.
            DiagnosticsLogger.shared.log(.info, subsystem: "credential-recovery",
                "needs manual sign-in account=\(accountNum)")
            status.phase = .needsManualSignIn
            statuses[accountNum] = status

        case .identityMismatch(let signedIn, let expected):
            // Wrong account authorised: terminal, retrying would repeat the mismatch.
            DiagnosticsLogger.shared.log(.warning, subsystem: "credential-recovery",
                "identity mismatch account=\(accountNum) signedInAs=\(signedIn) expected=\(expected)")
            status.phase = .needsManualSignIn
            statuses[accountNum] = status
        }
    }

    // MARK: - Helpers

    private func setPhase(_ phase: RecoveryPhase, for accountNum: Int) {
        var status = statuses[accountNum] ?? RecoveryStatus()
        status.phase = phase
        statuses[accountNum] = status
    }
}
