import Foundation

/// Workspace-feed subprocess calls. Mirrors backend/cmd/csw/cmd_workspace.go.
extension CswClient {
    /// Live, rule-derived action feed. Cheap enough to poll every few minutes —
    /// no Claude in the backend hot path.
    func workspaceFeed() async throws -> WorkspaceFeedDTO {
        try await run(["workspace", "feed", "--json"], decode: WorkspaceFeedDTO.self)
    }

    /// Ask Claude for a suggested action body for one signal. `instruction` +
    /// `previousDraft` drive the "Hỏi thêm" refine follow-up.
    func workspaceDraft(
        signal: WorkspaceSignalDTO,
        instruction: String = "",
        previousDraft: String = ""
    ) async throws -> WorkspaceDraftDTO {
        let payload = DraftRequest(
            kind: signal.kind.rawValue,
            source: signal.source.rawValue,
            title: signal.title,
            context: signal.context,
            actor: signal.actor,
            instruction: instruction,
            previousDraft: previousDraft
        )
        return try await runWithStdin(
            ["workspace", "draft", "--json"],
            stdin: encodeJSON(payload),
            decode: WorkspaceDraftDTO.self
        )
    }

    /// Perform an approved action. The caller must have shown a confirm step —
    /// this hits the provider write API directly.
    func workspaceExecute(signal: WorkspaceSignalDTO, text: String) async throws -> WorkspaceExecuteResultDTO {
        let payload = ExecuteRequest(kind: signal.kind.rawValue, text: text, meta: signal.meta ?? [:])
        return try await runWithStdin(
            ["workspace", "execute", "--json"],
            stdin: encodeJSON(payload),
            decode: WorkspaceExecuteResultDTO.self
        )
    }

    // MARK: - Request payloads (mirror Go DraftInput / WorkspaceAction)

    private struct DraftRequest: Encodable {
        let kind, source, title, context, actor, instruction, previousDraft: String
    }
    private struct ExecuteRequest: Encodable {
        let kind: String
        let text: String
        let meta: [String: String]
    }

    private func encodeJSON<T: Encodable>(_ v: T) -> String {
        guard let data = try? JSONEncoder().encode(v),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
