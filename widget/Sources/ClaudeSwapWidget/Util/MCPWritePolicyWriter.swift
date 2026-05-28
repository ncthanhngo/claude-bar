import Foundation

/// Persists write-gate policy toggles to a known path the Go MCP gateway reads
/// on each write-tool call. Keep the path in sync with
/// `backend/internal/adapter/paths.go MCPWritePolicyFile()`.
enum MCPWritePolicyWriter {
    private struct Policy: Encodable {
        let autoApproveSlackPostMessage: Bool
    }

    static var defaultURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return support
            .appendingPathComponent("claude-swap-widget", isDirectory: true)
            .appendingPathComponent("mcp-write-policy.json")
    }

    static func write(autoApproveSlackPostMessage: Bool, to url: URL = defaultURL) {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !autoApproveSlackPostMessage {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            let data = try JSONEncoder().encode(Policy(autoApproveSlackPostMessage: true))
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[MCPWritePolicyWriter] write failed: \(error.localizedDescription)")
        }
    }
}
