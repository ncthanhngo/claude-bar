import Foundation

/// Persists `AppSettings.briefingUserPrompt` to a known file path the Go
/// briefing runner reads on every `csw briefing run`. Cheap atomic write
/// — small files, no contention to worry about.
///
/// Path mirrors `backend/internal/adapter/paths.go BriefingUserPromptFile()`.
/// Keep both sides in sync when relocating.
enum BriefingUserPromptWriter {
    /// Default location: `~/Library/Application Support/claude-swap-widget/
    /// briefing-user-prompt.md`. Created on first write; parent dir may not
    /// exist on a fresh install so we mkdir before writing.
    static var defaultURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return support
            .appendingPathComponent("claude-swap-widget", isDirectory: true)
            .appendingPathComponent("briefing-user-prompt.md")
    }

    /// Write `text` atomically. Empty / whitespace-only string removes the
    /// file so the backend treats it as "no extra context".
    static func write(_ text: String, to url: URL = defaultURL) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[BriefingUserPromptWriter] write failed: \(error.localizedDescription)")
        }
    }
}
