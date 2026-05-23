import Foundation

/// Mirror of `backend/internal/mcp/GatePrompt`. Args are intentionally
/// `[String: AnyCodable]` because the LLM-resolved args are heterogeneous.
struct GatePromptDTO: Codable, Identifiable, Equatable {
    /// Unique per-call correlation id; widget echoes this when responding.
    let nonce: String
    let tool: String
    let risk: GateRisk
    let origin: GateOrigin
    let summary: String
    let args: [String: AnyCodable]
    let account: String?
    let createdAt: Date

    var id: String { nonce }

    enum CodingKeys: String, CodingKey {
        case nonce, tool, risk, origin, summary, args, account
        case createdAt
    }
}

/// Backend writes risk as a numeric enum; we mirror it.
enum GateRisk: Int, Codable {
    case low = 0
    case medium = 1
    case destructive = 2
    case readSensitive = 3
}

enum GateOrigin: Int, Codable {
    case llm = 0
    case capture = 1
    case rowAction = 2
}

/// Reply payload sent through the proxy. Mirrors the Go server envelope.
struct GateDecisionEnvelope: Encodable {
    let kind: String   // always "respond"
    let nonce: String
    let decision: String // "approved" | "cancelled" | "timeout"
}

/// Server-side envelope (read direction). The proxy passes through both
/// `hello` (one-shot greeting) and `prompt` lines.
struct GateInboundEnvelope: Decodable {
    let kind: String
    let prompt: GatePromptDTO?
}

/// Tiny `AnyCodable` so unknown arg shapes survive the round-trip.
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull(); return }
        if let v = try? c.decode(Bool.self) { self.value = v; return }
        if let v = try? c.decode(Int.self) { self.value = v; return }
        if let v = try? c.decode(Double.self) { self.value = v; return }
        if let v = try? c.decode(String.self) { self.value = v; return }
        if let v = try? c.decode([AnyCodable].self) { self.value = v.map(\.value); return }
        if let v = try? c.decode([String: AnyCodable].self) {
            self.value = v.mapValues(\.value)
            return
        }
        self.value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }

    static func == (a: AnyCodable, b: AnyCodable) -> Bool {
        String(describing: a.value) == String(describing: b.value)
    }

    /// Render a user-friendly one-line string for gate display ("key=value, …").
    static func render(_ args: [String: AnyCodable]) -> String {
        let pairs = args.keys.sorted().map { k -> String in
            "\(k)=\(args[k]?.value ?? "")"
        }
        return pairs.joined(separator: ", ")
    }
}
