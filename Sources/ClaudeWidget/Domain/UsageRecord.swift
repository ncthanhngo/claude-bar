import Foundation

/// One assistant-turn row from a Claude Code JSONL file.
struct UsageRecord {
    let timestamp: Date
    let sessionId: String
    let requestId: String?
    let messageId: String?
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int

    /// Combined token count used for rate-limit accounting (matches ccusage default).
    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Dedup key: prefer requestId+messageId, fall back to timestamp+sessionId.
    var dedupKey: String {
        if let r = requestId, let m = messageId { return "\(r)|\(m)" }
        return "\(sessionId)|\(timestamp.timeIntervalSince1970)"
    }
}

enum UsageRecordDecoder {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Decode one JSONL line. Returns nil for non-assistant rows or rows without usage data.
    static func decode(line: String) -> UsageRecord? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let tsStr = obj["timestamp"] as? String,
              let ts = iso.date(from: tsStr) ?? isoNoFrac.date(from: tsStr) else {
            return nil
        }

        return UsageRecord(
            timestamp: ts,
            sessionId: obj["sessionId"] as? String ?? "",
            requestId: obj["requestId"] as? String,
            messageId: message["id"] as? String,
            model: message["model"] as? String,
            inputTokens: (usage["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage["output_tokens"] as? Int) ?? 0,
            cacheCreationTokens: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheReadTokens: (usage["cache_read_input_tokens"] as? Int) ?? 0
        )
    }
}
