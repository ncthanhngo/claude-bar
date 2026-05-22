import Foundation

/// Wire shapes for the `csw chat …` command surface. JSON keys mirror the
/// snake_case the Go CLI emits; CodingKeys do the bridging so Swift APIs
/// stay camelCase.

struct ConversationDTO: Codable, Identifiable, Hashable {
    let id: String
    let accountUUID: String
    let title: String
    let model: String
    let systemPrompt: String?
    let archived: Bool
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case accountUUID = "account_uuid"
        case title
        case model
        case systemPrompt = "system_prompt"
        case archived
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ContentBlockDTO: Codable, Hashable {
    let kind: String          // "text" | "image" | "document" | "thinking" | "tool_use"
    let text: String?
    let attachmentID: String?
    let mediaType: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case text
        case attachmentID = "attachment_id"
        case mediaType = "media_type"
    }
}

struct MessageDTO: Codable, Identifiable, Hashable {
    let id: String
    let conversationID: String
    let role: String          // "user" | "assistant" | "system"
    let content: [ContentBlockDTO]
    let inputTokens: Int?
    let outputTokens: Int?
    let stopReason: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case role
        case content
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case stopReason = "stop_reason"
        case createdAt = "created_at"
    }

    /// Convenience: concatenate every text block. Used for previews + search.
    var plainText: String {
        content.compactMap { $0.kind == "text" ? $0.text : nil }.joined()
    }

    /// Convenience constructor for the optimistic local user bubble the
    /// composer shows the instant the user hits send — gets replaced by the
    /// server-side record once `chat send`'s `done` event arrives.
    static func localUser(
        conversationID: String,
        text: String,
        attachmentIDs: [String]
    ) -> MessageDTO {
        var blocks: [ContentBlockDTO] = attachmentIDs.map {
            ContentBlockDTO(kind: "image", text: nil, attachmentID: $0, mediaType: nil)
        }
        if !text.isEmpty {
            blocks.append(ContentBlockDTO(kind: "text", text: text, attachmentID: nil, mediaType: nil))
        }
        return MessageDTO(
            id: "local-" + UUID().uuidString,
            conversationID: conversationID,
            role: "user",
            content: blocks,
            inputTokens: nil, outputTokens: nil, stopReason: nil,
            createdAt: Date()
        )
    }

    /// Convenience constructor for the finalised assistant message the store
    /// appends when the stream completes (the `done` event carries the id).
    static func finalizedAssistant(
        id: String,
        conversationID: String,
        text: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> MessageDTO {
        MessageDTO(
            id: id,
            conversationID: conversationID,
            role: "assistant",
            content: [ContentBlockDTO(kind: "text", text: text, attachmentID: nil, mediaType: nil)],
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            stopReason: nil,
            createdAt: Date()
        )
    }
}

struct AttachmentDTO: Codable, Identifiable, Hashable {
    let id: String
    let conversationID: String
    let kind: String          // "image" | "pdf" | "text"
    let filename: String
    let mediaType: String
    let sizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case kind
        case filename
        case mediaType = "media_type"
        case sizeBytes = "size_bytes"
    }
}

/// Bundled response of `csw chat conversations load <id>`.
struct ConversationLoadDTO: Codable {
    let conversation: ConversationDTO
    let messages: [MessageDTO]
}

/// One event emitted by `csw chat send …` on stdout, one JSON per line.
/// The CLI's union shape is decoded into a Swift enum so callers can switch
/// exhaustively without reading raw dictionaries.
enum ChatStreamEvent: Decodable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case usage(input: Int, output: Int)
    case done(messageID: String, stopReason: String, input: Int, output: Int)
    case error(code: String, message: String, retryAfterSeconds: Int?)

    private enum CodingKeys: String, CodingKey {
        case kind, text
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case stopReason = "stop_reason"
        case messageID = "message_id"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case retryAfterS = "retry_after_s"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text_delta":
            self = .textDelta(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking_delta":
            self = .thinkingDelta(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "usage":
            self = .usage(
                input: try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
                output: try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            )
        case "done":
            self = .done(
                messageID: try c.decodeIfPresent(String.self, forKey: .messageID) ?? "",
                stopReason: try c.decodeIfPresent(String.self, forKey: .stopReason) ?? "",
                input: try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
                output: try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            )
        case "error":
            self = .error(
                code: try c.decodeIfPresent(String.self, forKey: .errorCode) ?? "unknown",
                message: try c.decodeIfPresent(String.self, forKey: .errorMessage) ?? "",
                retryAfterSeconds: try c.decodeIfPresent(Int.self, forKey: .retryAfterS)
            )
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "ChatStreamEvent: unknown kind \(kind)"
            ))
        }
    }
}
