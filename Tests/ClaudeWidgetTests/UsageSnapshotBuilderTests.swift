import XCTest
@testable import ClaudeWidget

final class UsageSnapshotBuilderTests: XCTestCase {

    private func makeBlock(tokens: Int = 1_000_000, messages: Int = 5) -> SessionBlock {
        SessionBlock(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 18_000),
            totalTokens: tokens,
            inputTokens: 0,
            outputTokens: tokens,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            messageCount: messages,
            models: []
        )
    }

    private func makeWebSnapshot(session: Double = 30, weekly: Double? = 50) -> WebUsageService.Snapshot {
        WebUsageService.Snapshot(
            sessionUtilization: session,
            sessionResetsAt: Date(timeIntervalSince1970: 1000),
            weeklyUtilization: weekly,
            weeklyResetsAt: Date(timeIntervalSince1970: 5000),
            fetchedAt: Date()
        )
    }

    // MARK: - Source priority

    func testPrefersWebOverJsonlWhenBothPresent() {
        let snap = UsageSnapshotBuilder.build(
            web: makeWebSnapshot(session: 30),
            jsonlBlock: makeBlock(tokens: 100_000_000),
            fallbackLimit: 100_000_000
        )
        XCTAssertEqual(snap.source, .web)
        XCTAssertEqual(snap.sessionPercent, 30)
    }

    func testFallsBackToJsonlWhenNoWeb() {
        let snap = UsageSnapshotBuilder.build(
            web: nil,
            jsonlBlock: makeBlock(tokens: 50_000_000),
            fallbackLimit: 100_000_000
        )
        XCTAssertEqual(snap.source, .jsonl)
        XCTAssertEqual(snap.sessionPercent, 50.0, accuracy: 0.01)
    }

    func testEmptyWhenNoData() {
        let snap = UsageSnapshotBuilder.build(
            web: nil,
            jsonlBlock: nil,
            fallbackLimit: 100_000_000
        )
        XCTAssertEqual(snap.source, .empty)
        XCTAssertEqual(snap.sessionPercent, 0)
    }

    // MARK: - JSONL math

    func testJsonlPercentClampsToHundred() {
        let snap = UsageSnapshotBuilder.build(
            web: nil,
            jsonlBlock: makeBlock(tokens: 999_000_000),
            fallbackLimit: 100_000_000
        )
        XCTAssertEqual(snap.sessionPercent, 100.0)
    }

    func testJsonlPercentZeroWhenLimitZero() {
        let snap = UsageSnapshotBuilder.build(
            web: nil,
            jsonlBlock: makeBlock(tokens: 1_000),
            fallbackLimit: 0
        )
        XCTAssertEqual(snap.sessionPercent, 0)
    }

    // MARK: - Web preserves JSONL block metadata

    func testWebPathStillSurfacesBlockTokens() {
        let snap = UsageSnapshotBuilder.build(
            web: makeWebSnapshot(),
            jsonlBlock: makeBlock(tokens: 12_345, messages: 7),
            fallbackLimit: 100_000
        )
        XCTAssertEqual(snap.blockTokens, 12_345)
        XCTAssertEqual(snap.messageCount, 7)
    }

    func testWebWithoutBlockGivesZeroBlockTokens() {
        let snap = UsageSnapshotBuilder.build(
            web: makeWebSnapshot(),
            jsonlBlock: nil,
            fallbackLimit: 100_000
        )
        XCTAssertEqual(snap.blockTokens, 0)
        XCTAssertEqual(snap.messageCount, 0)
    }
}
