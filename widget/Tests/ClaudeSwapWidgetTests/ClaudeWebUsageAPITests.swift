import XCTest
@testable import ClaudeSwapWidget

@MainActor
final class ClaudeWebUsageAPITests: XCTestCase {

    /// Regression: the live usage API returns `resets_at` with fractional
    /// seconds and a timezone offset. The plain `.iso8601` strategy rejected
    /// those, failing the whole decode ("no matching schema") on a valid 200
    /// response — which stuck the account's web-usage badge on "Sign in".
    func testDecodesFractionalSecondTimestamps() throws {
        let json = """
        {"five_hour":{"utilization":1.0,"resets_at":"2026-06-08T17:00:00.246364+00:00"},
         "seven_day":{"utilization":17.0,"resets_at":"2026-06-12T12:00:00.246392+00:00"},
         "seven_day_oauth_apps":null,"tangelo":null,"cinder_cove":null}
        """.data(using: .utf8)!

        let usage = try ClaudeWebUsageAPI.decode(data: json)
        XCTAssertEqual(usage.fiveHour?.utilizationPct, 1.0)
        XCTAssertEqual(usage.sevenDay?.utilizationPct, 17.0)
        XCTAssertNotNil(usage.fiveHour?.resetsAt)
        XCTAssertNotNil(usage.sevenDay?.resetsAt)
    }

    /// Older "Z" timestamps without fractional seconds must still decode.
    func testDecodesPlainZuluTimestamps() throws {
        let json = """
        {"five_hour":{"utilization":4.0,"resets_at":"2026-06-09T09:42:12Z"},
         "seven_day":{"utilization":10.0,"resets_at":"2026-06-12T12:00:00Z"}}
        """.data(using: .utf8)!

        let usage = try ClaudeWebUsageAPI.decode(data: json)
        XCTAssertEqual(usage.fiveHour?.utilizationPct, 4.0)
        XCTAssertEqual(usage.sevenDay?.utilizationPct, 10.0)
    }

    /// A null window (untouched quota on a new account) decodes to nil, not a
    /// hard failure.
    func testNullWindowDecodesToNil() throws {
        let json = """
        {"five_hour":null,"seven_day":{"utilization":3.0,"resets_at":"2026-06-12T12:00:00.5+00:00"}}
        """.data(using: .utf8)!

        let usage = try ClaudeWebUsageAPI.decode(data: json)
        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.sevenDay?.utilizationPct, 3.0)
    }

    /// The per-model weekly window ("Fable") is reported only inside the
    /// `limits` array — the legacy `seven_day_opus` field is null since the
    /// model rename, so the array is the sole source for that bar.
    func testDecodesScopedWeeklyLimitFromLimitsArray() throws {
        let json = """
        {"five_hour":{"utilization":11.0,"resets_at":"2026-09-10T06:39:59.911770+00:00"},
         "seven_day":{"utilization":70.0,"resets_at":"2026-09-11T11:59:59.911790+00:00"},
         "seven_day_opus":null,
         "limits":[
           {"kind":"session","percent":11,"resets_at":"2026-09-10T06:39:59.911770+00:00","scope":null},
           {"kind":"weekly_all","percent":70,"resets_at":"2026-09-11T11:59:59.911790+00:00","scope":null},
           {"kind":"weekly_scoped","percent":83,"resets_at":"2026-09-11T11:59:59.911939+00:00",
            "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
        """.data(using: .utf8)!

        let usage = try ClaudeWebUsageAPI.decode(data: json)
        XCTAssertEqual(usage.sevenDay?.utilizationPct, 70.0)
        XCTAssertEqual(usage.sevenDayScoped?.utilizationPct, 83.0)
        XCTAssertEqual(usage.scopedLabel, "Fable")
    }

    /// No `limits` array (or no per-model entry) leaves the scoped window nil
    /// so the popover simply omits that row.
    func testMissingScopedLimitDecodesToNil() throws {
        let json = """
        {"five_hour":{"utilization":4.0,"resets_at":"2026-06-09T09:42:12Z"},
         "seven_day":{"utilization":10.0,"resets_at":"2026-06-12T12:00:00Z"},
         "limits":[{"kind":"weekly_all","percent":10,"resets_at":"2026-06-12T12:00:00Z","scope":null}]}
        """.data(using: .utf8)!

        let usage = try ClaudeWebUsageAPI.decode(data: json)
        XCTAssertNil(usage.sevenDayScoped)
        XCTAssertNil(usage.scopedLabel)
    }
}
