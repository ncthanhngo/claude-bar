import Foundation

/// Persists `MCPConnectorPrompts` to a known file path the Go briefing
/// runner reads on every `csw briefing run`. Keep the path in sync with
/// `backend/internal/adapter/paths.go MCPConnectorPromptsFile()`.
enum MCPConnectorPromptsWriter {
    static var defaultURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return support
            .appendingPathComponent("claude-swap-widget", isDirectory: true)
            .appendingPathComponent("mcp-connector-prompts.json")
    }

    /// Atomic write of the JSON payload. Empty-or-default object removes
    /// the file so the backend treats it as "no per-connector overrides".
    static func write(_ prompts: MCPConnectorPrompts, to url: URL = defaultURL) {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if prompts == .empty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try prompts.encodeToJSON().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[MCPConnectorPromptsWriter] write failed: \(error.localizedDescription)")
        }
    }
}
