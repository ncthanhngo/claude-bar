import XCTest
@testable import ClaudeSwapWidget

/// Phase 3 — credential recovery state machine.
///
/// Covers the genuinely unit-testable pure logic: the coordinator's
/// eligibility / cooldown / retry-cap bookkeeping (driven through the real
/// `recover` path with a stubbed headless closure) and the state machine's
/// healthy-target selection. The full tick orchestration (notifications,
/// `switchTo`) is integration-level and exercised manually per the phase plan.
@MainActor
final class CredentialRecoveryTests: XCTestCase {

    // MARK: - Helpers

    private func account(_ n: Int) -> AccountDTO {
        AccountDTO(number: n, email: "user\(n)@example.com",
                   organizationName: nil, organizationUuid: nil,
                   nickname: nil, createdAt: Date())
    }

    private func view(_ n: Int, active: Bool, credState: String?, tier: String? = nil) -> AccountViewDTO {
        AccountViewDTO(account: account(n), isActive: active, usage: nil,
                       error: nil, credentialState: credState,
                       credentialError: nil, subscriptionType: tier)
    }

    // MARK: - Coordinator eligibility

    func testFreshAccountIsEligible() {
        let coord = CredentialRecoveryCoordinator()
        XCTAssertTrue(coord.isEligible(1))
        XCTAssertFalse(coord.isBusy)
    }

    func testSucceededClearsAllRecoveryState() async {
        let coord = CredentialRecoveryCoordinator()
        coord.headlessRelogin = { _ in .succeeded(displayName: "u1", wroteLive: true) }
        let outcome = await coord.recover(accountNum: 1)
        if case .succeeded = outcome {} else { XCTFail("expected succeeded, got \(String(describing: outcome))") }
        XCTAssertTrue(coord.isEligible(1))          // status cleared → eligible again
        XCTAssertFalse(coord.manualSignInRequired(1))
    }

    func testTransientFailureEntersCooldownThenBlocksUntilElapsed() async {
        let coord = CredentialRecoveryCoordinator()
        coord.headlessRelogin = { _ in .failed("network blip") }
        _ = await coord.recover(accountNum: 1)
        // One failure (< cap) → cooldown active → not eligible right now.
        XCTAssertFalse(coord.isEligible(1))
        XCTAssertFalse(coord.manualSignInRequired(1))
    }

    func testRetryCapMovesToManualSignIn() async {
        let coord = CredentialRecoveryCoordinator()
        coord.headlessRelogin = { _ in .failed("still dead") }
        // Three failures (the cap) → terminal needsManualSignIn.
        for _ in 0..<3 { _ = await coord.recover(accountNum: 1) }
        XCTAssertTrue(coord.manualSignInRequired(1))
        XCTAssertFalse(coord.isEligible(1))
    }

    func testIdentityMismatchIsTerminal() async {
        let coord = CredentialRecoveryCoordinator()
        coord.headlessRelogin = { _ in .identityMismatch(signedInAs: "other@x.com", expected: "user1@example.com") }
        _ = await coord.recover(accountNum: 1)
        XCTAssertTrue(coord.manualSignInRequired(1))
        XCTAssertFalse(coord.isEligible(1))
    }

    func testNeedsManualSignInOutcomeIsTerminal() async {
        let coord = CredentialRecoveryCoordinator()
        coord.headlessRelogin = { _ in .needsManualSignIn }
        _ = await coord.recover(accountNum: 1)
        XCTAssertTrue(coord.manualSignInRequired(1))
    }

    func testBusyOutcomeDoesNotBurnRetryBudget() async {
        let coord = CredentialRecoveryCoordinator()
        coord.headlessRelogin = { _ in .failed("busy") }
        _ = await coord.recover(accountNum: 1)
        // "busy" means no real attempt ran — account must stay eligible.
        XCTAssertTrue(coord.isEligible(1))
    }

    func testMissingHeadlessClosureDoesNotBurnRetryBudget() async {
        let coord = CredentialRecoveryCoordinator()   // headlessRelogin left nil
        _ = await coord.recover(accountNum: 1)
        XCTAssertTrue(coord.isEligible(1))
    }

    // MARK: - Healthy reconciliation (Phase 4)

    func testNoteHealthyClearsManualSignIn() async {
        let coord = CredentialRecoveryCoordinator()
        coord.headlessRelogin = { _ in .needsManualSignIn }
        _ = await coord.recover(accountNum: 1)
        XCTAssertTrue(coord.manualSignInRequired(1))
        coord.noteHealthy(1)
        XCTAssertFalse(coord.manualSignInRequired(1))
        XCTAssertTrue(coord.isEligible(1))
    }

    func testReconcileClearsAccountsReportingReady() async {
        let coord = CredentialRecoveryCoordinator()
        coord.headlessRelogin = { _ in .needsManualSignIn }
        _ = await coord.recover(accountNum: 3)
        XCTAssertTrue(coord.manualSignInRequired(3))
        // A fresh snapshot now reports account 3 healthy → flag must clear.
        let snap = ListAccountsDTO(accounts: [
            view(1, active: true, credState: "ready"),
            view(3, active: false, credState: "ready"),
        ], activeAccountNumber: 1)
        coord.reconcile(snap)
        XCTAssertFalse(coord.manualSignInRequired(3))
    }

    func testReconcileLeavesStillDeadAccountsFlagged() async {
        let coord = CredentialRecoveryCoordinator()
        coord.headlessRelogin = { _ in .needsManualSignIn }
        _ = await coord.recover(accountNum: 3)
        // Snapshot still shows account 3 needs_login → flag must persist.
        let snap = ListAccountsDTO(accounts: [
            view(3, active: false, credState: "needs_login"),
        ], activeAccountNumber: 1)
        coord.reconcile(snap)
        XCTAssertTrue(coord.manualSignInRequired(3))
    }

    // MARK: - Inactive sweep targeting

    func testRecoverInactiveSkipsActiveAndHealthy() async {
        let coord = CredentialRecoveryCoordinator()
        var attempted: [Int] = []
        coord.headlessRelogin = { n in attempted.append(n); return .succeeded(displayName: "u", wroteLive: false) }
        let snap = ListAccountsDTO(accounts: [
            view(1, active: true, credState: "needs_login"),   // active — must be skipped here
            view(2, active: false, credState: "ready"),        // healthy — skip
            view(3, active: false, credState: "needs_login"),  // the only valid target
        ], activeAccountNumber: 1)
        await coord.recoverInactiveIfNeeded(snap)
        XCTAssertEqual(attempted, [3])
    }

    // MARK: - Healthy target selection

    func testPickHealthyTargetExcludesNeedsLoginAndActive() {
        let sm = AutoSwapStateMachine(client: CswClient(), settings: AppSettings.shared)
        let snap = ListAccountsDTO(accounts: [
            view(1, active: true, credState: "needs_login"),
            view(2, active: false, credState: "needs_login"),   // dead — never a target
            view(3, active: false, credState: "ready"),         // healthy
        ], activeAccountNumber: 1)
        XCTAssertEqual(sm.pickHealthyTarget(snap)?.account.number, 3)
    }

    func testPickHealthyTargetTreatsNilCredentialStateAsHealthy() {
        let sm = AutoSwapStateMachine(client: CswClient(), settings: AppSettings.shared)
        let snap = ListAccountsDTO(accounts: [
            view(1, active: true, credState: "needs_login"),
            view(2, active: false, credState: nil),   // nil → assume healthy
        ], activeAccountNumber: 1)
        XCTAssertEqual(sm.pickHealthyTarget(snap)?.account.number, 2)
    }

    func testPickHealthyTargetPrefersHigherTier() {
        let sm = AutoSwapStateMachine(client: CswClient(), settings: AppSettings.shared)
        let snap = ListAccountsDTO(accounts: [
            view(1, active: true, credState: "needs_login"),
            view(2, active: false, credState: "ready", tier: "pro"),
            view(3, active: false, credState: "ready", tier: "max_200"),
        ], activeAccountNumber: 1)
        XCTAssertEqual(sm.pickHealthyTarget(snap)?.account.number, 3)
    }

    func testPickHealthyTargetNilWhenAllDead() {
        let sm = AutoSwapStateMachine(client: CswClient(), settings: AppSettings.shared)
        let snap = ListAccountsDTO(accounts: [
            view(1, active: true, credState: "needs_login"),
            view(2, active: false, credState: "needs_login"),
        ], activeAccountNumber: 1)
        XCTAssertNil(sm.pickHealthyTarget(snap))
    }
}
