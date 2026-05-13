import Foundation

/// User-tunable config persisted in Application Support.
struct WidgetConfig: Codable {
    var plan: Plan
    var customLimit: Int
    var activeAccountId: UUID?
    var autoSwitchEnabled: Bool
    var autoSwitchThresholdPercent: Double
    var includeCacheTokens: Bool

    static let `default` = WidgetConfig(
        plan: .max20,
        customLimit: 220_000_000,
        activeAccountId: nil,
        autoSwitchEnabled: false,
        autoSwitchThresholdPercent: 95,
        includeCacheTokens: true
    )

    /// Effective token cap for the chosen plan (used by JSONL fallback).
    var effectiveLimit: Int {
        plan == .custom ? customLimit : plan.defaultTokenLimit
    }
}

final class ConfigStore {

    static let shared = ConfigStore()

    private let url: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClaudeWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("config.json")
    }

    func load() -> WidgetConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(WidgetConfig.self, from: data) else {
            return .default
        }
        return cfg
    }

    func save(_ cfg: WidgetConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cfg) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
