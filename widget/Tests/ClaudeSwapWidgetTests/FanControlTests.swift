import XCTest
import SMCKit
@testable import ClaudeSwapWidget

/// Fan tab: the helper's command line, the custom-speed clamp, and how the
/// picker reads the SMC's current mode.
final class FanControlTests: XCTestCase {

    func testCommandRoundTripsThroughHelperArguments() {
        for cmd in [FanCommand.auto, .max, .rpm(2500)] {
            XCTAssertEqual(FanCommand.parse(cmd.arguments), cmd)
        }
    }

    func testHelperRejectsAnythingElse() {
        XCTAssertNil(FanCommand.parse([]))
        XCTAssertNil(FanCommand.parse(["auto", "x"]))
        XCTAssertNil(FanCommand.parse(["rpm"]))
        XCTAssertNil(FanCommand.parse(["rpm", "abc"]))
        XCTAssertNil(FanCommand.parse(["rpm", "0"]))
        XCTAssertNil(FanCommand.parse(["rpm", "-5"]))
        XCTAssertNil(FanCommand.parse(["off"]))
    }

    func testCustomSpeedIsClampedToFanRange() {
        XCTAssertEqual(FanCommand.rpm(200).targetRPM(min: 1000, max: 4900), 1000)
        XCTAssertEqual(FanCommand.rpm(9000).targetRPM(min: 1000, max: 4900), 4900)
        XCTAssertEqual(FanCommand.rpm(2500).targetRPM(min: 1000, max: 4900), 2500)
        XCTAssertEqual(FanCommand.max.targetRPM(min: 1000, max: 4900), 4900)
        XCTAssertNil(FanCommand.auto.targetRPM(min: 1000, max: 4900))
    }

    func testModeFollowsSMCState() {
        func fan(manual: Bool, target: Double) -> FanReading {
            FanReading(index: 0, actual: 1000, min: 1000, max: 4900, target: target, isManual: manual)
        }
        XCTAssertEqual(FanControlStore.mode(of: fan(manual: false, target: 4900)), .auto)
        XCTAssertEqual(FanControlStore.mode(of: fan(manual: true, target: 4900)), .max)
        XCTAssertEqual(FanControlStore.mode(of: fan(manual: true, target: 2500)), .custom)
    }

    func testReadingsArePlausibleWhenPresent() {
        // Fanless Macs and CI runners return no fans; that is fine.
        for f in Fans.read() {
            XCTAssertGreaterThan(f.max, f.min)
            XCTAssertGreaterThanOrEqual(f.actual, 0)
            XCTAssertLessThan(f.actual, 20_000)
        }
    }
}
