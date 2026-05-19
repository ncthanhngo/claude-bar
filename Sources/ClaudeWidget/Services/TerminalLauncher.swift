import Foundation

/// Spawns Terminal.app and runs a command via AppleScript. Used by the
/// "Add account" wizard to drive `claude logout && claude` for the user.
enum TerminalLauncher {

    enum LaunchError: LocalizedError {
        case osascriptMissing
        case scriptFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .osascriptMissing:
                return "/usr/bin/osascript not found."
            case .scriptFailed(let code, let stderr):
                return "Terminal launch failed (exit \(code)): \(stderr)"
            }
        }
    }

    /// Opens Terminal.app and runs `command` in a new window. Throws if
    /// AppleScript fails (typically when the user denies Automation
    /// permission for the widget).
    @discardableResult
    static func run(command: String) throws -> Int32 {
        let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
        guard FileManager.default.isExecutableFile(atPath: osascript.path) else {
            throw LaunchError.osascriptMissing
        }

        // Escape any embedded quotes for AppleScript.
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """

        let process = Process()
        process.executableURL = osascript
        process.arguments = ["-e", script]

        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let err = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw LaunchError.scriptFailed(process.terminationStatus, err)
        }
        return process.terminationStatus
    }
}
