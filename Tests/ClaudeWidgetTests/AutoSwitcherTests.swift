import XCTest
@testable import ClaudeWidget

@MainActor
final class AutoSwitcherTests: XCTestCase {

    // MARK: - Helpers

    private func makeAccount(label: String, percent: Double? = nil, createdAt: Date = Date()) -> Account {
        var acc = Account(label: label, oauthBlob: "blob-\(label)", createdAt: createdAt)
        acc.lastSessionPercent = percent
        return acc
    }

    // MARK: - Guards

    func testNoCandidateWhenFewerThanTwoAccounts() {
        let one = makeAccount(label: "solo")
        XCTAssertNil(AutoSwitcher.chooseCandidate(
            activeId: one.id, accounts: [one],
            currentPercent: 99, threshold: 90))
    }

    func testNoCandidateWhenBelowThreshold() {
        let a = makeAccount(label: "a")
        let b = makeAccount(label: "b", percent: 10)
        XCTAssertNil(AutoSwitcher.chooseCandidate(
            activeId: a.id, accounts: [a, b],
            currentPercent: 80, threshold: 90))
    }

    func testThresholdInclusive() {
        // currentPercent >= threshold (not strictly greater).
        let a = makeAccount(label: "a")
        let b = makeAccount(label: "b", percent: 10)
        XCTAssertNotNil(AutoSwitcher.chooseCandidate(
            activeId: a.id, accounts: [a, b],
            currentPercent: 90, threshold: 90))
    }

    // MARK: - Picking strategy

    func testPicksLowestUsageAmongObserved() {
        let a = makeAccount(label: "a")
        let b = makeAccount(label: "b", percent: 80)
        let c = makeAccount(label: "c", percent: 10)
        let d = makeAccount(label: "d", percent: 40)
        let pick = AutoSwitcher.chooseCandidate(
            activeId: a.id, accounts: [a, b, c, d],
            currentPercent: 95, threshold: 90)
        XCTAssertEqual(pick?.label, "c")
    }

    func testSkipsUnobservedWhenObservedExists() {
        // Regression: previous logic preferred nil (unobserved) accounts
        // first, which could switch into accounts known to be high.
        let a = makeAccount(label: "active")
        let stale = makeAccount(label: "stale", percent: 95) // known high
        let fresh = makeAccount(label: "fresh", percent: nil) // never polled
        let pick = AutoSwitcher.chooseCandidate(
            activeId: a.id, accounts: [a, stale, fresh],
            currentPercent: 99, threshold: 90)
        XCTAssertEqual(pick?.label, "stale",
            "Should prefer the observed account (even at 95%) over an unobserved unknown")
    }

    func testAllUnobservedFallsBackToFirstNonActive() {
        // When nothing's been polled, deterministic fallback = first non-active.
        let a = makeAccount(label: "active")
        let b = makeAccount(label: "b", percent: nil)
        let c = makeAccount(label: "c", percent: nil)
        let pick = AutoSwitcher.chooseCandidate(
            activeId: a.id, accounts: [a, b, c],
            currentPercent: 99, threshold: 90)
        XCTAssertEqual(pick?.label, "b")
    }

    func testActiveAccountNeverPickedAsCandidate() {
        let a = makeAccount(label: "active", percent: 10)
        let b = makeAccount(label: "b", percent: 50)
        let pick = AutoSwitcher.chooseCandidate(
            activeId: a.id, accounts: [a, b],
            currentPercent: 99, threshold: 90)
        XCTAssertEqual(pick?.label, "b",
            "Even if active has lowest %, it shouldn't be picked")
    }

    func testNilActiveIdTreatsAllAsCandidates() {
        let a = makeAccount(label: "a", percent: 50)
        let b = makeAccount(label: "b", percent: 20)
        let pick = AutoSwitcher.chooseCandidate(
            activeId: nil, accounts: [a, b],
            currentPercent: 99, threshold: 90)
        XCTAssertEqual(pick?.label, "b")
    }
}
