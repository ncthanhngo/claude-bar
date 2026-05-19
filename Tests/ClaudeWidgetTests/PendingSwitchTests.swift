import XCTest
@testable import ClaudeWidget

final class PendingSwitchTests: XCTestCase {

    private func makeAccount(label: String = "x") -> Account {
        Account(label: label, oauthBlob: "blob")
    }

    func testEquatableMatchesOnAllFields() {
        let acc = makeAccount()
        let when = Date(timeIntervalSince1970: 1_000)
        let a = PendingSwitch(targetAccount: acc, blockingPIDs: [1, 2], detectedAt: when)
        let b = PendingSwitch(targetAccount: acc, blockingPIDs: [1, 2], detectedAt: when)
        XCTAssertEqual(a, b)
    }

    func testInequalityOnDifferentPIDs() {
        let acc = makeAccount()
        let when = Date()
        let a = PendingSwitch(targetAccount: acc, blockingPIDs: [1], detectedAt: when)
        let b = PendingSwitch(targetAccount: acc, blockingPIDs: [1, 2], detectedAt: when)
        XCTAssertNotEqual(a, b)
    }

    func testInequalityOnDifferentTargets() {
        let when = Date()
        let a = PendingSwitch(targetAccount: makeAccount(label: "a"), blockingPIDs: [], detectedAt: when)
        let b = PendingSwitch(targetAccount: makeAccount(label: "b"), blockingPIDs: [], detectedAt: when)
        XCTAssertNotEqual(a, b)
    }
}
