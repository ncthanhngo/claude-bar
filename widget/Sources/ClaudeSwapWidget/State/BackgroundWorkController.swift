import Foundation

/// Single switch that pauses or resumes every background loop and helper
/// process the app runs. Backs the Settings → General "Pause background
/// activity" toggle (`AppSettings.dormantModeEnabled`).
///
/// When paused, the menu-bar UI stays alive and fully interactive — manual
/// usage refresh, account switching, and Settings all keep working — but
/// nothing polls, fetches, or spawns on a timer, and App Nap is allowed to
/// re-engage. The app sits as quiet as it did before it was installed.
///
/// All coordinators are held weakly; they are owned by the App's @StateObject
/// graph for the whole process lifetime. `register` is called once from
/// `wireCoordinatorsOnce`; `apply(dormant:)` runs there (to honour a persisted
/// pause on launch) and again from the Settings toggle.
@MainActor
final class BackgroundWorkController {
    static let shared = BackgroundWorkController()
    private init() {}

    private weak var store: AppStore?
    private weak var briefing: BriefingCoordinator?
    private weak var news: NewsFeedCoordinator?
    private weak var prefsSync: PreferencesCloudSync?
    private weak var webFallback: WebFallbackCoordinator?
    private weak var gate: GateCoordinator?

    func register(
        store: AppStore,
        briefing: BriefingCoordinator,
        news: NewsFeedCoordinator,
        prefsSync: PreferencesCloudSync,
        webFallback: WebFallbackCoordinator,
        gate: GateCoordinator
    ) {
        self.store = store
        self.briefing = briefing
        self.news = news
        self.prefsSync = prefsSync
        self.webFallback = webFallback
        self.gate = gate
    }

    /// Pause when `dormant`, otherwise resume. Idempotent — each underlying
    /// start/stop guards against double-invocation.
    func apply(dormant: Bool) {
        if dormant { pause() } else { resume() }
        DiagnosticsLogger.shared.log(.info, subsystem: "lifecycle",
            "background work \(dormant ? "paused (dormant)" : "resumed")")
    }

    /// Start every periodic loop + the gate proxy. Safe to call when already
    /// running. `store.start()` also re-acquires the App Nap opt-out and the
    /// wake observer; the gate proxy guards against a duplicate spawn.
    private func resume() {
        store?.start()
        briefing?.start()
        news?.start()
        prefsSync?.start()
        webFallback?.resumeKeepAlive()
        gate?.start()
    }

    /// Tear down every periodic loop, release App Nap, and stop the gate
    /// proxy subprocess. Interactive actions in the UI still function.
    private func pause() {
        store?.stop()
        briefing?.stop()
        news?.stop()
        prefsSync?.stop()
        webFallback?.stop()
        gate?.stop()
    }
}
