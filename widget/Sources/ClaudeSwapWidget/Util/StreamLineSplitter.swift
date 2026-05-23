import Foundation

/// Byte-level line splitter that survives partial UTF-8 codepoints arriving
/// across `Pipe.availableData` reads. Use one instance per reader; never
/// share across concurrent readers (it carries internal mutable buffer state).
///
/// Designed for the `csw chat send …` stdout where every JSON event ends in
/// `\n` and lines can be split arbitrarily across buffer chunks. We accumulate
/// raw bytes and only emit a line once we see `\n`, so a partial codepoint at
/// the end of a chunk stays in the buffer until the next chunk completes it.
///
/// Sendability justification: the splitter is captured by `Pipe`'s
/// `readabilityHandler` (a background-queue serial callback) and the same
/// process's `terminationHandler` (called once after the read handler is
/// detached). Both run on the same DispatchIO source, never concurrently,
/// and the splitter is owned by the enclosing `send(...)` factory closure
/// so there is no cross-task aliasing. `@unchecked Sendable` records the
/// invariant: no concurrent calls into `feed`/`flush`.
final class StreamLineSplitter: @unchecked Sendable {
    private var buffer = Data()

    /// Feed a chunk of bytes from the upstream pipe; invokes `emit` once per
    /// complete line (without the trailing `\n`). Empty lines are skipped.
    func feed(_ data: Data, emit: (String) -> Void) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let lf = buffer.firstIndex(of: 0x0A) {
            let lineBytes = buffer.subdata(in: buffer.startIndex..<lf)
            buffer.removeSubrange(buffer.startIndex...lf)
            guard !lineBytes.isEmpty,
                  let line = String(data: lineBytes, encoding: .utf8) else {
                continue
            }
            emit(line)
        }
    }

    /// Flush any trailing bytes without a final newline. Called on stream
    /// EOF so a CLI that forgot the last `\n` still surfaces the event.
    func flush(emit: (String) -> Void) {
        guard !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) else {
            buffer.removeAll(keepingCapacity: false)
            return
        }
        buffer.removeAll(keepingCapacity: false)
        if !line.isEmpty { emit(line) }
    }
}
