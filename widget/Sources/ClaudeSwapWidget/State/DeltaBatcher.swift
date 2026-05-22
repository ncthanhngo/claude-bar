import Foundation

/// Coalesces tiny streaming-text chunks into ~30Hz batches so SwiftUI doesn't
/// re-render the assistant bubble on every Anthropic token. The first chunk
/// schedules a flush after `interval`; everything received in that window
/// piles into the buffer and ships in one shot.
///
/// Used only by ChatStore on the @MainActor — not thread-safe.
@MainActor
final class DeltaBatcher {
    private var buffer: String = ""
    private var pending: Task<Void, Never>?
    private let interval: TimeInterval
    private let onFlush: (String) -> Void

    init(interval: TimeInterval = 0.033, onFlush: @escaping (String) -> Void) {
        self.interval = interval
        self.onFlush = onFlush
    }

    /// Append a chunk; schedules a flush if none is pending.
    func append(_ chunk: String) {
        buffer += chunk
        if pending != nil { return }
        pending = Task { @MainActor [weak self, interval] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            self?.flushNow()
        }
    }

    /// Force an immediate flush. Safe to call when buffer is empty.
    func flush() { flushNow() }

    /// Drop everything without flushing. Used on stream cancel / error so
    /// stale chunks don't surface after the streaming bubble has been hidden.
    func reset() {
        pending?.cancel()
        pending = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func flushNow() {
        pending?.cancel()
        pending = nil
        guard !buffer.isEmpty else { return }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: false)
        onFlush(chunk)
    }
}
