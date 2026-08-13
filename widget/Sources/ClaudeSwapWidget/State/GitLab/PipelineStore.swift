import Foundation

/// Polls the latest pipeline for each watched GitLab project and publishes the
/// "any pipeline running" signal that swaps the menu-bar label, plus the
/// per-watch latest pipeline shown in the GitLab popover pane.
///
/// Ports GitLabBar's `PipelineMonitor` behaviour onto Claude Bar's stack: same
/// async poll loop and `PipelineStatus.isActive` running-detection, but the API
/// call goes through the Go backend (`csw gitlab pipelines`) instead of a Swift
/// GitLab client, and watches persist in `AppSettings` rather than a bespoke
/// store.
@MainActor
final class PipelineStore: ObservableObject {
    /// User-configured watches (durably backed by `AppSettings.gitlabWatchesJSON`).
    @Published private(set) var watches: [GitLabWatch] = []
    /// Newest pipeline per watch id. Absent = not fetched yet / fetch failed.
    @Published private(set) var latest: [String: Pipeline] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private let client: CswClient
    private let settings = AppSettings.shared
    private var pollTask: Task<Void, Never>?
    private var popoverOpenedAt: Date?

    /// Steady-state poll cadence. GitLabBar defaults to 30s; pipelines don't
    /// change faster than a job boundary, so 30s keeps the bar responsive
    /// without hammering the instance.
    private static let pollIntervalSec = 30
    /// Tighter cadence for a short window after the popover opens so the pane
    /// reflects fresh state while in view.
    private static let boostedIntervalSec = 10
    private static let boostWindow: TimeInterval = 2 * 60

    init(client: CswClient) {
        self.client = client
        self.watches = Self.decodeWatches(settings.gitlabWatchesJSON)
    }

    // MARK: - Derived running state (drives the menu bar)

    /// Number of watched projects whose latest pipeline is occupying CI now.
    var runningCount: Int { latest.values.lazy.filter { $0.status.isActive }.count }

    /// `true` when at least one watched pipeline is active — the menu bar shows
    /// the pipeline indicator; otherwise it reverts to the Claude usage label.
    var anyRunning: Bool { latest.values.contains { $0.status.isActive } }

    // MARK: - Poll loop

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                let secs = self.nextIntervalSec()
                try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
                await self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called when the popover opens — kicks an immediate refresh and boosts
    /// cadence briefly (mirrors `AppStore.notePopoverOpened`).
    func notePopoverOpened() {
        popoverOpenedAt = Date()
        Task { await refresh() }
    }

    private func nextIntervalSec() -> Int {
        guard !watches.isEmpty else { return Self.pollIntervalSec }
        if let opened = popoverOpenedAt,
           Date().timeIntervalSince(opened) < Self.boostWindow {
            return Self.boostedIntervalSec
        }
        return Self.pollIntervalSec
    }

    /// Fetch the newest pipeline for each watch in parallel and republish.
    func refresh() async {
        let current = watches
        guard !current.isEmpty else {
            if !latest.isEmpty { latest = [:] }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var next: [String: Pipeline] = [:]
        var firstError: String?
        await withTaskGroup(of: (String, Result<Pipeline?, Error>).self) { group in
            for w in current {
                group.addTask { [client] in
                    do {
                        let pipes = try await client.gitlabListPipelines(
                            instance: w.instanceID, project: w.project, ref: w.ref, perPage: 1)
                        return (w.id, .success(pipes.first))
                    } catch {
                        return (w.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let pipe):
                    if let pipe { next[id] = pipe }
                case .failure(let err):
                    if firstError == nil { firstError = err.localizedDescription }
                }
            }
        }
        latest = next
        lastError = firstError
    }

    // MARK: - Watch management (persisted)

    func addWatch(_ watch: GitLabWatch) {
        watches.append(watch)
        persist()
        Task { await refresh() }
    }

    func removeWatch(id: String) {
        watches.removeAll { $0.id == id }
        latest.removeValue(forKey: id)
        persist()
    }

    private func persist() {
        settings.gitlabWatchesJSON = Self.encodeWatches(watches)
    }

    private static func decodeWatches(_ json: String) -> [GitLabWatch] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([GitLabWatch].self, from: data)
        else { return [] }
        return arr
    }

    private static func encodeWatches(_ watches: [GitLabWatch]) -> String {
        guard let data = try? JSONEncoder().encode(watches),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }
}
