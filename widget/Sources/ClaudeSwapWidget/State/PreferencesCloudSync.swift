import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Auto-syncs General / MCP / Daily tab settings across Macs via iCloud Drive.
///
/// Pattern matches CloudSyncCoordinator: writes a plain JSON file alongside the
/// encrypted accounts bundle at
/// `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeBar/preferences.json`.
/// Bird daemon syncs the file across all Macs signed into the same Apple ID.
/// No entitlement required — same trust boundary as `cloud-bundle.enc`.
///
/// Settings are user preferences (not secrets), so the file is plain JSON.
/// Tokens / credentials remain in the passphrase-encrypted bundle.
///
/// Pull policy: poll mtime every 60s + on app become active + on launch. When
/// the remote `updatedAt` is newer than the last-applied timestamp, decode the
/// snapshot and write each whitelisted key back into UserDefaults.
///
/// Push policy: observe `UserDefaults.didChangeNotification`, debounce 1.5s,
/// then write the current values. A SHA-256 of the values block is stored in
/// UserDefaults so unchanged content doesn't generate a no-op push.
@MainActor
final class PreferencesCloudSync: ObservableObject {

    static let shared = PreferencesCloudSync()

    /// Last successful push or pull timestamp. Surfaced in Diagnostics.
    @Published private(set) var lastSyncAt: Date?

    /// Non-fatal error from the most recent sync attempt. nil when iCloud Drive
    /// is simply absent (user not signed in) — that's a silent no-op.
    @Published private(set) var lastError: String?

    private let fm = FileManager.default
    private var pushTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// True while we apply a remote snapshot. Suppresses the push that would
    /// otherwise fire from UserDefaults.didChangeNotification and loop us back
    /// out to iCloud with our own writes.
    private var applying = false

    /// Last mtime we read from the file. Lets the poll loop skip work when bird
    /// hasn't touched the file since our last read.
    private var lastSeenMTime: Date?

    private let lastAppliedAtKey = "prefsCloudSyncLastAppliedAt"
    private let lastPushedHashKey = "prefsCloudSyncLastPushedHash"

    private init() {}

    // MARK: - Paths

    private var iCloudRoot: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    private var folderURL: URL {
        iCloudRoot.appendingPathComponent("ClaudeBar", isDirectory: true)
    }

    private var fileURL: URL {
        folderURL.appendingPathComponent("preferences.json")
    }

    private var iCloudAvailable: Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: iCloudRoot.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Lifecycle

    func start() {
        observeDefaultsChanges()
        observeAppActive()
        startPolling()
        Task { await self.pullIfNewer() }
    }

    func syncNow() async {
        await pullIfNewer()
        await pushNow()
    }

    // MARK: - Pull

    private func pullIfNewer() async {
        guard iCloudAvailable else { return }
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            let attrs = try fm.attributesOfItem(atPath: fileURL.path)
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            if let seen = lastSeenMTime, mtime <= seen { return }
            let data = try Data(contentsOf: fileURL)
            let snap = try decoder.decode(Snapshot.self, from: data)
            lastSeenMTime = mtime

            let lastApplied = UserDefaults.standard.double(forKey: lastAppliedAtKey)
            let remote = snap.updatedAt.timeIntervalSince1970
            // 1s slop so re-reading our own push is a no-op.
            guard remote > lastApplied + 1 else { return }

            apply(snap)
            UserDefaults.standard.set(remote, forKey: lastAppliedAtKey)
            lastSyncAt = snap.updatedAt
            lastError = nil
        } catch {
            lastError = "pull: \(error.localizedDescription)"
        }
    }

    private func apply(_ snap: Snapshot) {
        applying = true
        defer { applying = false }
        for key in syncedKeys {
            guard let v = snap.values[key.id] else { continue }
            key.applyToUserDefaults(value: v)
        }
    }

    // MARK: - Push

    private func observeDefaultsChanges() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard !self.applying else { return }
                    self.schedulePush()
                }
            }
        )
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushNow()
        }
    }

    private func pushNow() async {
        guard iCloudAvailable else { return }
        let snap = snapshotFromCurrentDefaults()
        let hash = snap.contentHash
        if hash == UserDefaults.standard.string(forKey: lastPushedHashKey) {
            return
        }
        do {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let data = try encoder.encode(snap)
            try data.write(to: fileURL, options: [.atomic])
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let mtime = attrs[.modificationDate] as? Date {
                lastSeenMTime = mtime
            }
            UserDefaults.standard.set(snap.updatedAt.timeIntervalSince1970, forKey: lastAppliedAtKey)
            UserDefaults.standard.set(hash, forKey: lastPushedHashKey)
            lastSyncAt = snap.updatedAt
            lastError = nil
        } catch {
            lastError = "push: \(error.localizedDescription)"
        }
    }

    // MARK: - Observers

    private func observeAppActive() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.pullIfNewer() }
            }
        )
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pullIfNewer() }
        }
    }

    // MARK: - Snapshot

    private func snapshotFromCurrentDefaults() -> Snapshot {
        var values: [String: JSONValue] = [:]
        for key in syncedKeys {
            if let v = key.readFromUserDefaults() {
                values[key.id] = v
            }
        }
        return Snapshot(
            version: 1,
            updatedAt: Date(),
            device: ProcessInfo.processInfo.hostName,
            values: values
        )
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Snapshot model

private struct Snapshot: Codable {
    let version: Int
    let updatedAt: Date
    let device: String
    let values: [String: JSONValue]

    /// SHA-256 of the values dict (sorted keys) — excludes timestamp + device so
    /// re-encoding the same settings yields the same hash and dedupes pushes.
    var contentHash: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let data = try? e.encode(values) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum JSONValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Order matters: Bool decodes from JSON true/false only — try first
        // so "1"/"0" doesn't get mis-typed as Bool on some platforms.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            .init(codingPath: c.codingPath, debugDescription: "unsupported JSON scalar")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

// MARK: - Synced keys

private struct SyncedKey {
    enum Kind { case bool, int, double, string }
    let id: String
    let kind: Kind

    func readFromUserDefaults() -> JSONValue? {
        let d = UserDefaults.standard
        guard d.object(forKey: id) != nil else { return nil }
        switch kind {
        case .bool:   return .bool(d.bool(forKey: id))
        case .int:    return .int(d.integer(forKey: id))
        case .double: return .double(d.double(forKey: id))
        case .string: return d.string(forKey: id).map(JSONValue.string)
        }
    }

    func applyToUserDefaults(value: JSONValue) {
        let d = UserDefaults.standard
        switch (kind, value) {
        case (.bool, .bool(let v)):     d.set(v, forKey: id)
        case (.int, .int(let v)):       d.set(v, forKey: id)
        case (.double, .double(let v)): d.set(v, forKey: id)
        case (.string, .string(let v)): d.set(v, forKey: id)
        default: break
        }
    }
}

/// Whitelist of UserDefaults keys covered by iCloud sync. Tabs: General, MCP,
/// Daily. Throttle timestamps and local-file paths (avatar) are intentionally
/// excluded — they're machine-specific.
private let syncedKeys: [SyncedKey] = [
    // General tab
    .init(id: "autoSwapEnabled",          kind: .bool),
    .init(id: "thresholdPct",             kind: .int),
    .init(id: "refreshIntervalSec",       kind: .int),
    .init(id: "refreshIntervalHighSec",   kind: .int),
    .init(id: "adaptiveHighThresholdPct", kind: .int),
    .init(id: "sessionPollIntervalSec",   kind: .int),
    .init(id: "menuBarStyle",             kind: .string),
    .init(id: "menuBarIconColor",         kind: .string),
    .init(id: "aggressiveAutoKill",       kind: .bool),
    .init(id: "autoReloadIDEAfterSwap",   kind: .bool),
    .init(id: "autoKillCLIAfterSwap",     kind: .bool),
    .init(id: "reloadShortcut",           kind: .string),
    .init(id: "injectReloadShortcut",     kind: .bool),
    .init(id: "widgetTheme",              kind: .string),

    // MCP tab
    .init(id: "mcpConnectorPromptsJSON",  kind: .string),

    // Daily tab
    .init(id: "dailyMode",                              kind: .string),
    .init(id: "dailyProfileName",                       kind: .string),
    .init(id: "briefingHotkeyOpenAppKeyCode",           kind: .int),
    .init(id: "briefingHotkeyOpenAppModifiers",         kind: .int),
    .init(id: "briefingHotkeyOpenBriefingKeyCode",      kind: .int),
    .init(id: "briefingHotkeyOpenBriefingModifiers",    kind: .int),
    .init(id: "briefingNewsFeedsJSON",                  kind: .string),
    .init(id: "briefingNewsFetchTime",                  kind: .string),
    .init(id: "briefingNewsFetchesPerDay",              kind: .int),
    .init(id: "briefingScheduleTimes",                  kind: .string),
    .init(id: "briefingUserPrompt",                     kind: .string),
]
