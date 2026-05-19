import Foundation

/// Locates the `claude` CLI binary on disk. Used by the magic-link login flow
/// when the widget needs to spawn `claude` as a subprocess.
enum ClaudeBinaryLocator {

    /// Tries `which claude` first (respects user's PATH including nvm),
    /// then falls back to common install locations.
    static func find() -> String? {
        if let viaWhich = which() { return viaWhich }
        for candidate in commonPaths() {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func which() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // `env` runs in user's login shell context only via -i; use plain
        // which which will use the env we inherit. nvm shims usually live
        // in PATH already if launched from a normal app context.
        process.arguments = ["which", "claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    private static func commonPaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.nvm/versions/node/current/bin/claude"
        ]
    }
}
