import Foundation
import Combine

/// Drives the live Workspace feed: polls `csw workspace feed` on an interval,
/// publishes the signal list + health, and tracks which signal IDs are new
/// since the user last looked so the UI can badge "N mới".
///
/// Distinct from BriefingCoordinator (the once-a-day editorial briefing) — this
/// is the cheap, pollable action surface. Lives only while the Workspace tab is
/// on screen; `start()`/`stop()` are driven by the view's lifecycle.
@MainActor
final class WorkspaceCoordinator: ObservableObject {
    @Published private(set) var feed: WorkspaceFeedDTO?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    /// IDs present in the feed that the user hasn't acknowledged yet.
    @Published private(set) var newSignalIDs: Set<String> = []

    /// Re-poll cadence. Short enough to feel live, long enough to stay cheap.
    private let pollInterval: TimeInterval = 3 * 60

    private let client = CswClient()
    private var pollTask: Task<Void, Never>?
    /// IDs the user has already seen across refreshes — basis for the "new" diff.
    private var seenIDs: Set<String> = []

    /// Begin polling. Idempotent — a second call replaces the prior loop.
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 180) * 1_000_000_000))
                await self?.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Force an immediate refresh (pull-to-refresh / manual button).
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let f = try await client.workspaceFeed()
            let incoming = Set(f.signals.map(\.id))
            // New = present now but never seen. First load seeds `seenIDs`
            // without flagging everything as "new".
            if seenIDs.isEmpty {
                seenIDs = incoming
                newSignalIDs = []
            } else {
                newSignalIDs = incoming.subtracting(seenIDs)
                seenIDs.formUnion(incoming)
            }
            feed = f
            lastError = nil
        } catch {
            lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Clear the "new" badges once the user has looked at the feed.
    func acknowledgeNew() {
        newSignalIDs = []
    }
}
