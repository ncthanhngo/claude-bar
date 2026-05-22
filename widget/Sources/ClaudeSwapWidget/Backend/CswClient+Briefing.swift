import Foundation

/// Briefing-specific subprocess calls. Mirrors backend/cmd/csw/cmd_briefing.go.
extension CswClient {
    func briefingRun(force: Bool = false) async throws -> BriefingDTO {
        var args = ["briefing", "run", "--json"]
        if force { args.append("--force") }
        return try await run(args, decode: BriefingDTO.self)
    }

    func briefingShow(date: String? = nil) async throws -> BriefingDTO {
        var args = ["briefing", "show", "--json"]
        if let d = date {
            args.append("--date")
            args.append(d)
        }
        return try await run(args, decode: BriefingDTO.self)
    }

    func briefingScheduleGet() async throws -> BriefingScheduleDTO {
        try await run(["briefing", "schedule", "get", "--json"], decode: BriefingScheduleDTO.self)
    }

    func briefingScheduleSet(cron: String, enabled: Bool, timezone: String = "Asia/Saigon") async throws {
        _ = try await runRaw([
            "briefing", "schedule", "set", "--json",
            "--cron", cron,
            "--enabled", String(enabled),
            "--tz", timezone,
        ])
    }

    func briefingScheduleCheck() async throws -> BriefingScheduleCheckDTO {
        try await run(["briefing", "schedule", "check", "--json"], decode: BriefingScheduleCheckDTO.self)
    }

    func briefingToggleAction(date: String, id: String, done: Bool) async throws -> BriefingDTO {
        try await run([
            "briefing", "action", "toggle", "--json",
            "--date", date,
            "--id", id,
            "--done", String(done),
        ], decode: BriefingDTO.self)
    }
}
