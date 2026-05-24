import Foundation

/// Chat-mode RPCs over the `csw chat …` CLI surface.
///
/// `chatSend` is special: it returns an AsyncThrowingStream because the
/// underlying CLI emits one JSON event per line as the assistant streams.
/// Everything else is one-shot JSON via the existing `run` helper, with
/// stdin used for any user-supplied bytes (filenames, file contents,
/// search queries) so user content never lands in argv.
extension CswClient {

    // MARK: - Conversations

    func chatConversationsList() async throws -> [ConversationDTO] {
        try await run(["chat", "conversations", "list"], decode: [ConversationDTO].self)
    }

    func chatConversationCreate(
        model: String,
        title: String,
        systemPrompt: String?
    ) async throws -> ConversationDTO {
        var args: [String] = ["chat", "conversations", "create",
                              "--model", model, "--title", title]
        if let sp = systemPrompt, !sp.isEmpty {
            args.append("--system-prompt-stdin")
            return try await runDecodingWithStdin(args, stdin: sp, decode: ConversationDTO.self)
        }
        return try await run(args, decode: ConversationDTO.self)
    }

    func chatConversationLoad(_ id: String) async throws -> ConversationLoadDTO {
        try await run(["chat", "conversations", "load", id], decode: ConversationLoadDTO.self)
    }

    func chatConversationRename(_ id: String, title: String) async throws {
        struct Resp: Decodable { let id: String; let title: String }
        _ = try await run(
            ["chat", "conversations", "rename", id, "--title", title],
            decode: Resp.self
        )
    }

    func chatConversationSetModel(_ id: String, model: String) async throws {
        struct Resp: Decodable { let id: String; let model: String }
        _ = try await run(
            ["chat", "conversations", "set-model", id, "--model", model],
            decode: Resp.self
        )
    }

    func chatConversationDelete(_ id: String) async throws {
        struct Resp: Decodable { let id: String; let status: String }
        _ = try await run(
            ["chat", "conversations", "delete", id],
            decode: Resp.self
        )
    }

    // MARK: - Send

    /// Returns the streaming event channel. The caller MUST loop over it
    /// (with `for try await event in …`) so the underlying Process can
    /// progress. Cancelling the consumer's Task sends SIGINT to the CLI.
    nonisolated func chatSend(
        conversationID: String,
        text: String,
        attachmentIDs: [String],
        permissionMode: String? = nil,
        contextInject: ChatStreamReader.ContextInject? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        ChatStreamReader.send(
            conversationID: conversationID,
            text: text,
            attachmentIDs: attachmentIDs,
            permissionMode: permissionMode,
            contextInject: contextInject
        )
    }

    // MARK: - Attachments

    func chatAttach(
        conversationID: String,
        filename: String,
        mediaType: String,
        data: Data
    ) async throws -> AttachmentDTO {
        try await runDecodingWithRawStdin(
            ["chat", "attach", conversationID,
             "--filename", filename, "--media-type", mediaType],
            stdin: data,
            decode: AttachmentDTO.self
        )
    }

    /// Streams the decrypted attachment bytes from `csw chat attachment read`.
    /// Used by the historical-preview path — UI clicks a chip on a past
    /// message, we fetch + cache via AttachmentPreviewCache.
    func chatAttachmentRead(id: String) async throws -> Data {
        try await runRaw(["chat", "attachment", "read", id])
    }

    // MARK: - Search

    func chatSearch(query: String, limit: Int = 50) async throws -> [MessageDTO] {
        try await run(
            ["chat", "search", "--query", query, "--limit", String(limit)],
            decode: [MessageDTO].self
        )
    }

    // MARK: - Local helpers (private to this extension)

    private func runDecodingWithStdin<T: Decodable>(
        _ args: [String],
        stdin payload: String,
        decode: T.Type
    ) async throws -> T {
        let raw = try await runRawWithStdin(args, stdin: Data(payload.utf8))
        do {
            return try JSONDecoder.csw.decode(T.self, from: raw)
        } catch {
            let str = String(data: raw, encoding: .utf8) ?? "<binary>"
            throw CswError.decodingFailed(underlying: error, raw: str)
        }
    }

    private func runDecodingWithRawStdin<T: Decodable>(
        _ args: [String],
        stdin payload: Data,
        decode: T.Type
    ) async throws -> T {
        let raw = try await runRawWithStdin(args, stdin: payload)
        do {
            return try JSONDecoder.csw.decode(T.self, from: raw)
        } catch {
            let str = String(data: raw, encoding: .utf8) ?? "<binary>"
            throw CswError.decodingFailed(underlying: error, raw: str)
        }
    }

    private func runRawWithStdin(_ args: [String], stdin payload: Data) async throws -> Data {
        guard let bin = CswBinary.resolve() else { throw CswError.binaryNotFound }
        return try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.executableURL = bin
            task.arguments = args
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardInput = stdin
            task.standardOutput = stdout
            task.standardError = stderr
            task.terminationHandler = { proc in
                let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: outData)
                } else {
                    let msg = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: CswError.nonZeroExit(
                        code: proc.terminationStatus,
                        stderr: CswError.redact(msg)
                    ))
                }
            }
            do {
                try task.run()
                let h = stdin.fileHandleForWriting
                try h.write(contentsOf: payload)
                try h.close()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// Shared decoder reused across the chat extension. Mirrors the date parsing
/// of CswClient's actor-internal one so date fields decode the same way.
extension JSONDecoder {
    static let csw: JSONDecoder = {
        let d = JSONDecoder()
        // See CswClient.swift for the rationale — ISO8601DateFormatter is
        // non-Sendable, Date.ISO8601FormatStyle is. Identical wire-format
        // coverage (with + without fractional seconds).
        let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        d.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            if let date = try? withFractional.parse(str) { return date }
            if let date = try? plain.parse(str) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unparseable ISO8601 date: \(str)"
            ))
        }
        return d
    }()
}
