import Foundation

/// Drains assistant text into the UI one small slice at a time so users see
/// a steady, readable reveal instead of the bursty chunks that arrive from
/// the model. Used by ChatStore on the @MainActor — not thread-safe.
///
/// Rate is adaptive: when the backlog is small we reveal ~55 chars/sec
/// (comfortable reading pace); as the backlog grows we accelerate so we
/// never let the buffer drift more than a couple of seconds behind the
/// real stream. `flushNow()` reveals everything immediately and is the
/// path used on `.done` to finalize the assistant message without making
/// the user wait through a slow trailing reveal.
@MainActor
final class TypewriterRenderer {
    private var buffer: [Character] = []
    private var displayed: String = ""
    private var pump: Task<Void, Never>?
    private let onUpdate: (String) -> Void

    /// 18 ms between ticks → at 1 char/tick that's ~55 chars/sec.
    private let tickIntervalNs: UInt64 = 18_000_000

    init(onUpdate: @escaping (String) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Push more text into the buffer; starts the pump if it isn't running.
    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        buffer.append(contentsOf: chunk)
        ensurePump()
    }

    /// Reveal everything remaining in one synchronous update and return the
    /// fully-revealed text. Used on `.done` so the final MessageDTO carries
    /// the complete assistant reply without a trailing slow drain.
    @discardableResult
    func flushNow() -> String {
        pump?.cancel()
        pump = nil
        if !buffer.isEmpty {
            displayed.append(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: false)
            onUpdate(displayed)
        }
        return displayed
    }

    /// Drop everything without notifying. Used on cancel/error.
    func reset() {
        pump?.cancel()
        pump = nil
        buffer.removeAll(keepingCapacity: false)
        displayed.removeAll(keepingCapacity: false)
    }

    private func ensurePump() {
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            await self?.runPump()
        }
    }

    private func runPump() async {
        while !Task.isCancelled {
            if buffer.isEmpty {
                pump = nil
                return
            }
            let take = chunkSize(backlog: buffer.count)
            let n = min(take, buffer.count)
            let slice = buffer.prefix(n)
            displayed.append(contentsOf: slice)
            buffer.removeFirst(n)
            onUpdate(displayed)
            try? await Task.sleep(nanoseconds: tickIntervalNs)
        }
        pump = nil
    }

    /// Adaptive reveal rate. Keeps the visible lag under ~2s even on very
    /// fast responses while still feeling like a typewriter for short ones.
    private func chunkSize(backlog: Int) -> Int {
        switch backlog {
        case 0...30:     return 1   // ~55 ch/s — reading pace
        case 31...120:   return 2   // ~110 ch/s
        case 121...350:  return 4   // ~220 ch/s
        case 351...800:  return 8   // ~440 ch/s
        default:         return 16  // catch-up burst, still smooth
        }
    }
}
