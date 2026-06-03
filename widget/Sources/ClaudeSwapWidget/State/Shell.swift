import Foundation

/// Tiny synchronous shell runner for the Tools health/maintenance features.
/// Synchronous on purpose — callers run it inside `Task.detached` to stay off
/// the main actor.
enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `/bin/sh -c "<cmd>"` convenience.
    static func sh(_ cmd: String) -> String { run("/bin/sh", ["-c", cmd]) }

    /// Run a command with admin rights via osascript — macOS shows the native
    /// password prompt. Returns true on success (false if cancelled/failed).
    static func admin(_ cmd: String) -> Bool {
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
}
