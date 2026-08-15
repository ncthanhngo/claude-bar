import Foundation

/// Holds the currently rendered `NewsFeed` for `NewsDashboardView`.
///
/// Reads the persisted snapshot for an instant paint (`csw news show`), then —
/// on a **master** machine — aggregates in the background when the snapshot is
/// stale or empty (`csw news fetch`). A **client** machine never runs local AI:
/// it renders whatever snapshot it holds (Phase 4 replaces that with a pull
/// from the SSH relay). The manual refresh button forces a fresh aggregation.
@MainActor
final class NewsStore: ObservableObject {
    @Published private(set) var feed: NewsFeed = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    /// Permanent bookmark store (contract.md "Saved items") — loaded once on
    /// window open via `loadSaved()`, kept in sync locally by `toggleSaveItem`/
    /// `toggleSaveRepo` (optimistic update + rollback on a failed round-trip).
    @Published private(set) var savedItems: [NewsCard] = []
    @Published private(set) var savedRepos: [RepoCard] = []
    private var savedItemIDs: Set<String> = []
    private var savedRepoIDs: Set<String> = []

    private let client: CswClient
    private let settings: AppSettings
    private var autoRefreshTask: Task<Void, Never>?
    /// Re-entrancy guard: the window open path and the view's `.task` can both
    /// call `refresh()` on first show. Without this, both pass the stale/empty
    /// checks before either sets `isLoading` and fire two concurrent
    /// `csw news fetch` aggregations (each a full feed+GitHub+LLM run).
    private var isInFlight = false

    init(client: CswClient = CswClient(), settings: AppSettings = .shared) {
        self.client = client
        self.settings = settings
    }

    /// Loads/updates the feed.
    /// - non-force: paints the persisted snapshot instantly, then (master only)
    ///   aggregates in the background if that snapshot is stale or empty.
    /// - force (manual refresh): aggregates now, master only.
    func refresh(force: Bool = false) async {
        guard !isInFlight else { return }
        isInFlight = true
        defer { isInFlight = false }
        error = nil

        // 1. Instant paint from the last persisted snapshot (both roles) so the
        //    window never opens blank while the slow path runs.
        if let cached = try? await client.newsShow() {
            feed = cached
        }

        // 2. A client never aggregates locally — it pulls the master's snapshot
        //    from the SSH relay and renders that.
        if settings.newsRole == "client" {
            await pullFromRelay()
            return
        }

        // 3. Master: aggregate when forced, or when the snapshot is stale/empty,
        //    then publish to the relay (if one is configured) for clients.
        guard force || isStale(feed) else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            feed = try await client.newsFetch(force: force)
            await publishToRelayIfConfigured()
        } catch {
            // Keep any cached snapshot on screen; only surface a hard error
            // when there is nothing to fall back to.
            if feed == .empty {
                self.error = Self.friendlyError(error)
            }
        }
    }

    /// Client path: pull + verify the master's snapshot from the relay. Keeps
    /// the last cached snapshot on screen (with a note) when the relay is
    /// unreachable, so a Client is never left blank by a transient outage.
    private func pullFromRelay() async {
        let host = settings.newsRelayHostID.trimmingCharacters(in: .whitespaces)
        let dir = settings.newsRelayRemoteDir.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !dir.isEmpty else {
            if feed == .empty {
                error = "Chưa cấu hình relay host cho máy Client (Cài đặt → News)."
            }
            return
        }
        isLoading = (feed == .empty)
        defer { isLoading = false }
        do {
            feed = try await client.newsPull(host: host, dir: dir)
        } catch {
            if feed == .empty {
                self.error = Self.friendlyError(error)
            } else {
                self.error = "Không kết nối được Master — đang hiển thị bản lưu gần nhất."
            }
        }
    }

    /// Master path: best-effort publish of the fresh snapshot to the relay.
    /// A publish failure never fails the local refresh (the master still shows
    /// its own feed); the error surfaces only as a soft note.
    private func publishToRelayIfConfigured() async {
        let host = settings.newsRelayHostID.trimmingCharacters(in: .whitespaces)
        let dir = settings.newsRelayRemoteDir.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !dir.isEmpty else { return }
        do {
            try await client.newsPublish(host: host, dir: dir)
        } catch {
            self.error = "Đã tổng hợp xong nhưng chưa đẩy được lên relay: \(error.localizedDescription)"
        }
    }

    /// True when the snapshot was never generated or is older than the
    /// configured refresh interval.
    private func isStale(_ feed: NewsFeed) -> Bool {
        guard let generated = NewsDateFormatting.parse(feed.generatedAt) else { return true }
        let intervalHours = max(1, settings.newsRefreshIntervalHours)
        return -generated.timeIntervalSinceNow >= Double(intervalHours) * 3600
    }

    // MARK: - Saved items (permanent bookmarks — never pruned)

    func isItemSaved(_ id: String) -> Bool { savedItemIDs.contains(id) }
    func isRepoSaved(_ id: String) -> Bool { savedRepoIDs.contains(id) }

    /// Loads the bookmark store. Best-effort: a failure leaves whatever was
    /// last loaded (typically empty on first call) rather than surfacing a
    /// hard error — bookmarks are a secondary feature relative to the feed.
    func loadSaved() async {
        guard let saved = try? await client.newsSaved() else { return }
        savedItems = saved.items
        savedRepos = saved.repos
        savedItemIDs = Set(saved.items.map(\.id))
        savedRepoIDs = Set(saved.repos.map(\.id))
    }

    /// Optimistic toggle: flips local state immediately (so the UI feels
    /// instant), then persists via the bridge; rolls the local state back if
    /// the round-trip fails so the bookmark button never lies about what's
    /// actually saved.
    func toggleSaveItem(_ item: NewsCard) async {
        if savedItemIDs.contains(item.id) {
            savedItemIDs.remove(item.id)
            savedItems.removeAll { $0.id == item.id }
            do {
                try await client.newsUnsave(kind: "item", id: item.id)
            } catch {
                savedItemIDs.insert(item.id)
                if !savedItems.contains(where: { $0.id == item.id }) { savedItems.insert(item, at: 0) }
            }
        } else {
            savedItemIDs.insert(item.id)
            savedItems.insert(item, at: 0)
            do {
                try await client.newsSave(kind: "item", payloadJSON: Self.encode(item))
            } catch {
                savedItemIDs.remove(item.id)
                savedItems.removeAll { $0.id == item.id }
            }
        }
    }

    func toggleSaveRepo(_ repo: RepoCard) async {
        if savedRepoIDs.contains(repo.id) {
            savedRepoIDs.remove(repo.id)
            savedRepos.removeAll { $0.id == repo.id }
            do {
                try await client.newsUnsave(kind: "repo", id: repo.id)
            } catch {
                savedRepoIDs.insert(repo.id)
                if !savedRepos.contains(where: { $0.id == repo.id }) { savedRepos.insert(repo, at: 0) }
            }
        } else {
            savedRepoIDs.insert(repo.id)
            savedRepos.insert(repo, at: 0)
            do {
                try await client.newsSave(kind: "repo", payloadJSON: Self.encode(repo))
            } catch {
                savedRepoIDs.remove(repo.id)
                savedRepos.removeAll { $0.id == repo.id }
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Auto-refresh (gated on window visibility for energy)

    /// Starts the periodic background refresh loop. Called when the News window
    /// opens; `endAutoRefresh()` cancels it on close so a hidden window costs
    /// nothing (matches the v13.3 idle-CPU goal).
    func beginAutoRefresh() {
        endAutoRefresh()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let hours = max(1, self.settings.newsRefreshIntervalHours)
                try? await Task.sleep(for: .seconds(Double(hours) * 3600))
                if Task.isCancelled { return }
                await self.refresh()
            }
        }
    }

    func endAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private static func friendlyError(_ error: Error) -> String {
        "Không tải được tin: \(error.localizedDescription)"
    }
}
