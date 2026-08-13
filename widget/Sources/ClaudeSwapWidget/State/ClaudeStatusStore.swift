import Foundation
import SwiftUI
import UserNotifications

/// Watches Anthropic's public status page (status.claude.com, an Atlassian
/// Statuspage) so every user learns about a Claude outage without leaving the
/// menu bar. Polls the tiny `status.json` endpoint (indicator + description
/// only, ~200 bytes) on a fixed cadence WHILE THE APP IS OPEN, conditional on
/// an ETag so most requests come back `304 Not Modified` at near-zero cost.
///
/// Fires a macOS notification on the escalation edge into a *major* or worse
/// outage (and once on recovery), never per poll. Notifications honour the
/// app's quiet-hours window and the `claudeStatusAlertsEnabled` toggle; the
/// glanceable menu-bar dot + popover banner always reflect the live level.
///
/// Registered with `BackgroundWorkController`, so the Settings dormant toggle
/// pauses this loop with everything else. Like the server monitor it only runs
/// while the app is open — not a 24/7 watch.
@MainActor
final class ClaudeStatusStore: ObservableObject {
    /// Severity levels Statuspage reports via `status.indicator`.
    enum Level: Int, Comparable {
        case none = 0, minor = 1, major = 2, critical = 3

        init(_ raw: String) {
            switch raw.lowercased() {
            case "none":     self = .none
            case "minor":    self = .minor
            case "major":    self = .major
            case "critical": self = .critical
            // "maintenance" or any future value → treat as a soft (minor)
            // signal: shown in the UI, but below the notification threshold.
            default:         self = .minor
            }
        }

        static func < (l: Level, r: Level) -> Bool { l.rawValue < r.rawValue }
    }

    @Published private(set) var level: Level = .none
    /// Human-readable summary from the page (e.g. "Minor Service Outage").
    @Published private(set) var summary: String = ""
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?

    /// Notifications fire only for this level and above (product decision).
    private let notifyThreshold: Level = .major

    private let feedURL = URL(string: "https://status.claude.com/api/v2/status.json")!
    private var pollTask: Task<Void, Never>?
    private var etag: String?

    // Edge state: the severity we last raised an alert for. 0 = all clear.
    private var alertedLevel: Level = .none

    private var settings: AppSettings { AppSettings.shared }

    /// The menu bar shows a coloured dot only for a notify-worthy outage, so the
    /// glance matches what actually pinged the user.
    var shouldBadge: Bool { level >= notifyThreshold }

    /// Tint for the badge / banner dot.
    var tint: Color {
        switch level {
        case .none:     return .green
        case .minor:    return .yellow
        case .major:    return .orange
        case .critical: return .red
        }
    }

    // MARK: - lifecycle (driven by BackgroundWorkController)

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refreshNow()
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.nextIntervalNanos())
                if Task.isCancelled { return }
                await self.refreshNow()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-check every minute while an outage is live so recovery is noticed
    /// promptly; otherwise use the user's configured cadence.
    private func nextIntervalNanos() -> UInt64 {
        let baseMin = max(1, settings.claudeStatusPollMinutes)
        let secs = level >= notifyThreshold ? min(60, baseMin * 60) : baseMin * 60
        return UInt64(secs) * 1_000_000_000
    }

    // MARK: - poll

    func refreshNow() async {
        do {
            guard let payload = try await fetch() else { return }  // 304, nothing changed
            let newLevel = Level(payload.status.indicator)
            level = newLevel
            summary = payload.status.description
            lastUpdated = Date()
            lastError = nil
            evaluateEdge(level: newLevel, summary: payload.status.description)
        } catch is CancellationError {
            // paused / superseded — leave state as-is
        } catch {
            lastError = "\(error.localizedDescription)"
        }
    }

    /// Returns the decoded payload, or `nil` when the server answered `304 Not
    /// Modified` (ETag unchanged) so there's nothing to re-process. The network
    /// `await` suspends without blocking the main actor; the payload is tiny so
    /// decoding it here is negligible.
    private func fetch() async throws -> StatusPayload? {
        var req = URLRequest(url: feedURL, timeoutInterval: 12)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("ClaudeBar status monitor", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let tag = etag { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ClaudeStatus", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "phản hồi không hợp lệ"])
        }
        if http.statusCode == 304 { return nil }
        if http.statusCode >= 400 {
            throw NSError(domain: "ClaudeStatus", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        if let tag = http.value(forHTTPHeaderField: "Etag") { etag = tag }
        return try JSONDecoder().decode(StatusPayload.self, from: data)
    }

    private struct StatusPayload: Decodable {
        struct Status: Decodable { let indicator: String; let description: String }
        let status: Status
    }

    // MARK: - edge detection → notifications

    private func evaluateEdge(level: Level, summary: String) {
        if level >= notifyThreshold {
            // First entry into an outage, or an escalation (major → critical).
            if level > alertedLevel {
                if isQuietNow() { return }   // defer; fires once the window ends
                let title = level == .critical
                    ? "🔴 Claude gián đoạn nghiêm trọng"
                    : "🟠 Claude đang gặp sự cố"
                notify(title: title,
                       body: "\(summary). Xem chi tiết tại status.claude.com.",
                       id: "csw.claudestatus.outage")
                alertedLevel = level
            }
        } else if alertedLevel >= notifyThreshold {
            // Dropped back below the outage threshold — recovered.
            alertedLevel = .none
            if isQuietNow() { return }       // silent clear during quiet hours
            notify(title: "🟢 Claude đã hoạt động lại",
                   body: summary.isEmpty ? "Dịch vụ trở lại bình thường." : summary,
                   id: "csw.claudestatus.recovered")
        }
    }

    private func notify(title: String, body: String, id: String) {
        guard settings.claudeStatusAlertsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(req) }
    }

    // MARK: - quiet hours (reuses the app's quiet-hours setting)

    private func isQuietNow() -> Bool {
        guard let s = minutesOfDay(settings.quietHoursStart),
              let e = minutesOfDay(settings.quietHoursEnd), s != e else { return false }
        let cal = Calendar.current
        let now = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
        return s < e ? (now >= s && now < e) : (now >= s || now < e)
    }

    private func minutesOfDay(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }
}
