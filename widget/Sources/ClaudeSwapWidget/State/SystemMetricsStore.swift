import Foundation

/// App-level monitor for this Mac's local hardware metrics. Currently just the
/// CPU die temperature (see `CPUTemperature`), polled on a fixed cadence WHILE
/// THE APP IS OPEN and surfaced in the menu-bar label.
///
/// Registered with `BackgroundWorkController` so the Settings dormant toggle
/// pauses this loop with everything else. Polling only runs when the user has
/// opted in via `AppSettings.menuBarShowCPUTemp`; when the toggle is off we
/// skip the sensor read entirely and clear any stale value.
@MainActor
final class SystemMetricsStore: ObservableObject {
    /// Latest CPU die temperature in °C, or nil when off / no reading.
    @Published private(set) var cpuTempC: Double?

    private var pollTask: Task<Void, Never>?

    /// Sensor read is cheap; 5s keeps the readout live without busy-polling.
    private let intervalNanos: UInt64 = 5 * 1_000_000_000

    private var settings: AppSettings { AppSettings.shared }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refreshNow()
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.intervalNanos)
                if Task.isCancelled { return }
                await self.refreshNow()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One sample. Off-thread sensor read so the main actor never blocks;
    /// respects the opt-in toggle and clears the value when disabled.
    func refreshNow() async {
        guard settings.menuBarShowCPUTemp else {
            if cpuTempC != nil { cpuTempC = nil }
            return
        }
        let reading = await Task.detached(priority: .utility) {
            CPUTemperature.readCelsius()
        }.value
        cpuTempC = reading
    }
}
