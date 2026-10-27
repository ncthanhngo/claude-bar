import XCTest
import IOKit.pwr_mgt
@testable import ClaudeSwapWidget

/// Away mode holds one sleep assertion while locked and lets it go on unlock.
@MainActor
final class AwayModeControllerTests: XCTestCase {

    func testStartHoldsAwakeAndLocks() {
        var held = 0, locks = 0
        let away = AwayModeController(
            holdAwake: { held += 1; return 7 }, releaseAwake: { _ in }, lockScreen: { locks += 1 })
        away.start()
        away.start()
        XCTAssertTrue(away.isAway)
        XCTAssertEqual(held, 1, "a second start reuses the held assertion")
        XCTAssertEqual(locks, 2)
    }

    func testUnlockReleasesAssertion() {
        var released: [IOPMAssertionID] = []
        let away = AwayModeController(
            holdAwake: { 7 }, releaseAwake: { released.append($0) }, lockScreen: {})
        away.start()
        DistributedNotificationCenter.default().post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        let done = expectation(description: "unlock delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(away.isAway)
        XCTAssertEqual(released, [7])
    }

    func testFailedAssertionStillLocks() {
        var locks = 0
        let away = AwayModeController(holdAwake: { nil }, releaseAwake: { _ in }, lockScreen: { locks += 1 })
        away.start()
        XCTAssertFalse(away.isAway)
        XCTAssertEqual(locks, 1)
    }
}
