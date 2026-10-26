import XCTest
@testable import ClaudeSwapWidget

/// Quota auto-swap target selection.
@MainActor
final class AutoSwapPickTargetTests: XCTestCase {

    private func view(_ n: Int, active: Bool, fiveHour: Double, sevenDay: Double?) -> AccountViewDTO {
        let reset = Date().addingTimeInterval(3600)
        let usage = UsageDTO(
            fiveHour: UsageWindowDTO(utilizationPct: fiveHour, resetsAt: reset),
            sevenDay: sevenDay.map { UsageWindowDTO(utilizationPct: $0, resetsAt: reset) },
            sevenDayScoped: nil, scopedLabel: nil, fetchedAt: Date())
        return AccountViewDTO(
            account: AccountDTO(number: n, email: "user\(n)@example.com",
                                organizationName: nil, organizationUuid: nil,
                                nickname: nil, createdAt: Date()),
            isActive: active, usage: usage, error: nil,
            credentialState: nil, credentialError: nil, subscriptionType: nil)
    }

    private func pick(_ accounts: [AccountViewDTO]) -> Int? {
        let sm = AutoSwapStateMachine(client: CswClient(), settings: AppSettings.shared)
        return sm.pickTarget(ListAccountsDTO(accounts: accounts, activeAccountNumber: 1),
                             threshold: 80)?.account.number
    }

    func testSkipsWeeklyCappedAccountEvenWithLowFiveHour() {
        XCTAssertEqual(pick([
            view(1, active: true, fiveHour: 90, sevenDay: 50),
            view(2, active: false, fiveHour: 5, sevenDay: 100),   // weekly-capped
            view(3, active: false, fiveHour: 40, sevenDay: 60),
        ]), 3)
    }

    func testNilWhenOnlyCandidateIsWeeklyCapped() {
        XCTAssertNil(pick([
            view(1, active: true, fiveHour: 90, sevenDay: 50),
            view(2, active: false, fiveHour: 5, sevenDay: 100),
        ]))
    }

    func testMissingSevenDayDoesNotExclude() {
        XCTAssertEqual(pick([
            view(1, active: true, fiveHour: 90, sevenDay: 50),
            view(2, active: false, fiveHour: 10, sevenDay: nil),
        ]), 2)
    }
}
