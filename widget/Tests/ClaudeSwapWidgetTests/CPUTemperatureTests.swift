import XCTest
@testable import ClaudeSwapWidget

/// Verifies the CPU temperature reader (Util/CPUTemperature.swift) either
/// returns a plausible live reading on Apple Silicon or degrades to nil —
/// never a crash or a garbage value — and that the store respects its opt-in.
final class CPUTemperatureTests: XCTestCase {

    func testReadCelsiusIsNilOrPlausible() {
        // On CI/other hardware the sensors may be absent → nil is acceptable.
        // When present, a die temperature must land in a sane physical range.
        if let temp = CPUTemperature.readCelsius() {
            XCTAssertGreaterThan(temp, 0)
            XCTAssertLessThan(temp, 120, "CPU die temp should be well under 120°C")
        }
    }

    func testAverageDropsImplausibleSamplesAndMeansTheRest() {
        // Sleeping cores report placeholders (0, -4, 1.5, 2.3°C) and the SMC
        // occasionally emits garbage; none of it may drag the mean.
        XCTAssertEqual(CPUTemperature.average([60, 70, 0, -4, 1.5, 2.3, 250, -9201]), 65)
        XCTAssertNil(CPUTemperature.average([]))
        XCTAssertNil(CPUTemperature.average([0, 0, 130]))
    }

    @MainActor
    func testStoreClearsValueWhenToggleOff() async {
        AppSettings.shared.menuBarShowCPUTemp = false
        let store = SystemMetricsStore()
        await store.refreshNow()
        XCTAssertNil(store.cpuTempC, "disabled toggle must never populate a reading")
    }
}
