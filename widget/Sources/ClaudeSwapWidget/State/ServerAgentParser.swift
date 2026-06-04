import Foundation

/// Parses the assistant's streamed text for the agentic loop: it extracts the
/// first ```run command block (the assistant's request to run something) and
/// computes the "visible" text shown in the chat bubble with that block
/// stripped out — the command renders as its own cell instead.
enum ServerAgentParser {

    /// The first command inside a ```run … ``` fence, trimmed. nil when the
    /// assistant produced no run block this turn (it's done or needs input).
    static func firstCommand(in text: String) -> String? {
        guard let body = firstFenceBody(in: text) else { return nil }
        // One command per turn: take the first non-empty line, drop comments.
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            return t
        }
        return nil
    }

    /// Assistant prose with the run fence removed, trimmed.
    static func visibleText(_ text: String) -> String {
        guard let range = fenceRange(in: text) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = text
        out.removeSubrange(range)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: fence scanning

    /// Body text between an opening ```run (optionally still-streaming, so the
    /// closing fence may be absent) and the next ``` if present.
    private static func firstFenceBody(in text: String) -> String? {
        guard let open = openFenceIndex(in: text) else { return nil }
        let afterOpen = text[open...]
        guard let nl = afterOpen.firstIndex(of: "\n") else { return nil }
        let body = text[text.index(after: nl)...]
        if let close = body.range(of: "```") {
            return String(body[..<close.lowerBound])
        }
        // No closing fence yet — only treat as a command once it's closed, so a
        // mid-stream partial line isn't run prematurely.
        return nil
    }

    /// Character range of the whole ```run … ``` block (for stripping), or nil.
    private static func fenceRange(in text: String) -> Range<String.Index>? {
        guard let open = openFenceIndex(in: text) else { return nil }
        let afterOpen = text[open...]
        guard let nl = afterOpen.firstIndex(of: "\n") else { return nil }
        let body = text[text.index(after: nl)...]
        guard let close = body.range(of: "```") else { return nil }
        return open..<close.upperBound
    }

    /// Index of the start of the opening ```run fence (allowing whitespace
    /// after the language tag), case-insensitive on the `run` tag.
    private static func openFenceIndex(in text: String) -> String.Index? {
        let lower = text.lowercased()
        for marker in ["```run", "``` run"] {
            if let r = lower.range(of: marker) {
                return text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))
            }
        }
        return nil
    }
}
