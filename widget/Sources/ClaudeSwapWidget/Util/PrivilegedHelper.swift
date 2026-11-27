import Foundation

/// A tiny setuid-root tool shipped next to the app's executable and installed
/// once into /Library/PrivilegedHelperTools behind the native admin password
/// prompt. Used by the fan control and the AWDL guard.
struct PrivilegedHelper: Sendable {
    /// Executable name inside Contents/MacOS, e.g. "ClaudeBarFanHelper".
    let bundledName: String
    /// Suffix of the installed copy, e.g. "fan-helper".
    let installedSuffix: String

    static let fan = PrivilegedHelper(bundledName: "ClaudeBarFanHelper", installedSuffix: "fan-helper")
    static let net = PrivilegedHelper(bundledName: "ClaudeBarNetHelper", installedSuffix: "net-helper")

    /// Root-owned copy the app actually runs. Named per bundle id so Claude
    /// Bar and AI Bar never overwrite each other's helper.
    var installedPath: String {
        "/Library/PrivilegedHelperTools/\(Bundle.main.bundleIdentifier ?? "dev.ncthanhngo.claude-bar").\(installedSuffix)"
    }

    /// The helper shipped inside the app, next to the main executable.
    var bundledPath: String? {
        let path = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent(bundledName).path
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// Installed, root-owned and setuid — usable without a prompt.
    var isInstalled: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: installedPath),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue else { return false }
        return perms & 0o4000 != 0
    }

    /// Installed and identical to the bundled copy, so an app update that
    /// changes the helper reinstalls it.
    func isCurrent(bundled: String) -> Bool {
        isInstalled && FileManager.default.contentsEqual(atPath: installedPath, andPath: bundled)
    }

    enum InstallResult { case ok, notBundled, denied }

    /// Installs (or refreshes) the helper, asking for the admin password only
    /// when the installed copy is missing or outdated. Blocks.
    func ensureInstalled() -> InstallResult {
        guard let bundled = bundledPath else { return .notBundled }
        if isCurrent(bundled: bundled) { return .ok }
        let dest = Self.quoted(installedPath)
        let ok = Shell.admin("mkdir -p /Library/PrivilegedHelperTools && cp \(Self.quoted(bundled)) \(dest)"
            + " && chown root:wheel \(dest) && chmod 4755 \(dest)")
        return ok ? .ok : .denied
    }

    /// Runs the installed helper and returns its exit status (-1 if it could
    /// not start). Blocks.
    func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: installedPath)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
