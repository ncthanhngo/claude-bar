import Foundation

/// Locates the `csw` Go binary.
///
/// Resolution order:
///   1. `CSW_BIN` env var (dev override)
///   2. Bundled inside .app at `Contents/Resources/csw`
///   3. `/usr/local/bin/csw`, `/opt/homebrew/bin/csw`
///   4. `PATH` lookup via `/usr/bin/which`
enum CswBinary {
    static func resolve() -> URL? {
#if DEBUG
        // Dev override: point CSW_BIN at a locally built binary.
        // Stripped from release builds — only the bundled binary is trusted there.
        if let env = ProcessInfo.processInfo.environment["CSW_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
#endif
        if let bundled = Bundle.main.url(forResource: "csw", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for path in ["/usr/local/bin/csw", "/opt/homebrew/bin/csw"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
#if DEBUG
        return whichLookup()
#else
        return nil
#endif
    }

#if DEBUG
    private static func whichLookup() -> URL? {
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["csw"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
#endif
}
