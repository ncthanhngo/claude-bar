import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Detects running IDE instances that have the Claude Code extension active,
/// then reloads their windows so they pick up the freshly-swapped credentials.
///
/// Detection source: `~/.claude/ide/{port}.lock`
/// Primary reload: VSCode gets the configured Cmd+Shift+R reload shortcut;
/// other supported editors use Cmd+Shift+P → "Developer: Reload Window".
///   Events are routed directly to the IDE process to avoid frontmost-app races.
/// Fallback (no Accessibility): kill the claude-vscode backend; VSCode restarts it.
enum IDEReloader {

    // MARK: - Accessibility gate

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as NSDictionary as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Public API

    @discardableResult
    @MainActor
    static func reloadAll() async -> [String] {
        let instances = await detect()
        guard !instances.isEmpty else { return [] }

        var reloaded: [String] = []

        if isAccessibilityGranted {
            let reloadable = instances.filter { bundleId(for: $0.ideName) != nil }
            for group in Dictionary(grouping: reloadable, by: \.ideName).values {
                guard let ide = group.first else { continue }
                let count = await reloadAllWindows(for: ide)
                reloaded.append(contentsOf: Array(repeating: ide.displayName, count: count))
            }
        }

        // Kill extension backends for ALL IDEs (VSCode-family + JetBrains)
        killExtensionSessions()

        return reloaded.isEmpty ? instances.map { $0.displayName } : reloaded
    }

    @discardableResult
    static func killExtensionSessions() -> [Int] {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
        guard let entries = try? FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var killed: [Int] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let entrypoint = json["entrypoint"] as? String,
                  let kind = json["kind"] as? String,
                  kind == "interactive",
                  entrypoint != "cli",
                  kill(Int32(pid), 0) == 0 || errno == EPERM else { continue }
            kill(Int32(pid), SIGINT)
            killed.append(pid)
        }
        return killed
    }

    // MARK: - Detection

    struct IDEInstance {
        let port: Int
        let pid: Int
        let ideName: String
        let processName: String?   // kept for diagnostics
        let displayName: String
    }

    static func detect() async -> [IDEInstance] {
        let ideDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/ide")
        guard let entries = try? FileManager.default
            .contentsOfDirectory(at: ideDir, includingPropertiesForKeys: nil) else { return [] }

        var found: [IDEInstance] = []
        for entry in entries where entry.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: entry),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid  = json["pid"] as? Int,
                  let name = json["ideName"] as? String,
                  isAlive(pid: pid) else { continue }

            let port = Int(entry.deletingPathExtension().lastPathComponent) ?? 0
            found.append(IDEInstance(
                port: port, pid: pid, ideName: name,
                processName: processName(for: name),
                displayName: shortName(for: name)
            ))
        }
        return found
    }

    // MARK: - Reload via CGEvent (@MainActor — uses ClaudeBar's AX permission)

    @MainActor
    private static func reloadAllWindows(for ide: IDEInstance) async -> Int {
        guard let bid = bundleId(for: ide.ideName),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
        else { return 0 }

        let windows = appWindows(for: app)
        guard !windows.isEmpty else { return await reload(app, ideName: ide.ideName, window: nil) ? 1 : 0 }

        var count = 0
        for window in windows where await reload(app, ideName: ide.ideName, window: window) {
            count += 1
        }
        return count
    }

    @MainActor
    private static func reload(_ app: NSRunningApplication, ideName: String, window: AXUIElement?) async -> Bool {
        if isVSCode(ideName) {
            return await reloadVSCode(app, window: window)
        }
        return await reloadFromCommandPalette(app, window: window)
    }

    @MainActor
    private static func reloadVSCode(_ app: NSRunningApplication, window: AXUIElement?) async -> Bool {
        let prevApp = focus(app, window: window)
        try? await Task.sleep(nanoseconds: 800_000_000)

        // The user-configured VSCode shortcut reloads the window without typing
        // into whichever text field currently has focus.
        guard postKey(15, [.maskCommand, .maskShift], to: app.processIdentifier) else { return false }

        try? await Task.sleep(nanoseconds: 300_000_000)
        restoreFrontmost(prevApp)
        return true
    }

    @MainActor
    private static func reloadFromCommandPalette(_ app: NSRunningApplication, window: AXUIElement?) async -> Bool {
        // Save and set clipboard — paste bypasses IME (Vietnamese etc.)
        let pb = NSPasteboard.general
        let savedClip: [(NSPasteboard.PasteboardType, Data)] = pb.pasteboardItems?.flatMap { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        } ?? []
        pb.clearContents()
        pb.setString(">Developer: Reload Window", forType: .string)

        let prevApp = focus(app, window: window)
        defer {
            pb.clearContents()
            for (type, data) in savedClip { pb.setData(data, forType: type) }
        }

        try? await Task.sleep(nanoseconds: 800_000_000)

        // Cmd+Shift+P — open command palette
        guard postKey(35, [.maskCommand, .maskShift], to: app.processIdentifier) else { return false }
        try? await Task.sleep(nanoseconds: 700_000_000)
        // Cmd+A — select all in palette input
        guard postKey(0, .maskCommand, to: app.processIdentifier) else { return false }
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Cmd+V — paste ">Developer: Reload Window"
        guard postKey(9, .maskCommand, to: app.processIdentifier) else { return false }
        try? await Task.sleep(nanoseconds: 600_000_000)
        // Return — execute
        guard postKey(36, [], to: app.processIdentifier) else { return false }

        try? await Task.sleep(nanoseconds: 300_000_000)
        restoreFrontmost(prevApp)

        return true
    }

    @MainActor
    static func diagnose() async -> String {
        var log: [String] = []
        let ax = isAccessibilityGranted
        log.append("AX:\(ax ? "✓" : "✗")")

        let instances = await detect()
        if instances.isEmpty {
            log.append("IDEs: none (check ~/.claude/ide/*.lock)")
            return log.joined(separator: "\n")
        }

        for ide in instances {
            let bid = bundleId(for: ide.ideName)
            let app = bid.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            log.append("\(ide.displayName): lockPid=\(ide.pid) bundleId=\(bid ?? "nil") appPid=\(app?.processIdentifier.description ?? "not found")")
        }

        if !ax {
            let killed = killExtensionSessions()
            log.append("No AX — killed backends: \(killed)")
            return log.joined(separator: "\n")
        }

        let reloadable = instances.filter { bundleId(for: $0.ideName) != nil }
        for group in Dictionary(grouping: reloadable, by: \.ideName).values {
            guard let ide = group.first else { continue }
            log.append("→ reloading \(ide.displayName) windows...")
            let count = await reloadAllWindows(for: ide)
            log.append("  reloaded windows: \(count)")
        }

        let killed = killExtensionSessions()
        log.append("killed backends: \(killed)")
        return log.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func isAlive(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }

    /// Post key down+up to the IDE process, not whichever app happens to be frontmost.
    private static func postKey(_ keyCode: CGKeyCode, _ flags: CGEventFlags, to pid: pid_t) -> Bool {
        guard let dn = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return false }
        dn.flags = flags
        up.flags = flags
        dn.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private static func appWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return [] }
        return windows
    }

    private static func focus(_ window: AXUIElement, in app: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
    }

    @MainActor
    private static func focus(_ app: NSRunningApplication, window: AXUIElement?) -> NSRunningApplication? {
        let prevApp = NSWorkspace.shared.frontmostApplication
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window {
            focus(window, in: axApp)
        }
        return prevApp
    }

    private static func restoreFrontmost(_ app: NSRunningApplication?) {
        guard let app else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private static func isVSCode(_ ideName: String) -> Bool {
        ideName == "Visual Studio Code" || ideName == "Visual Studio Code - Insiders"
    }

    private static func bundleId(for ideName: String) -> String? {
        switch ideName {
        case "Visual Studio Code":            return "com.microsoft.VSCode"
        case "Visual Studio Code - Insiders": return "com.microsoft.VSCodeInsiders"
        case "Cursor":                        return "com.todesktop.230313mzl4w4u92"
        case "Windsurf":                      return "com.exafunction.windsurf"
        case "Zed":                           return "dev.zed.Zed"
        default:                              return nil
        }
    }

    private static func processName(for ideName: String) -> String? {
        switch ideName {
        case "Visual Studio Code":            return "Code"
        case "Visual Studio Code - Insiders": return "Code - Insiders"
        case "Cursor":                        return "Cursor"
        case "Windsurf":                      return "Windsurf"
        case "Zed":                           return "Zed"
        default:                              return nil
        }
    }

    private static func shortName(for ideName: String) -> String {
        switch ideName {
        case "Visual Studio Code":            return "VSCode"
        case "Visual Studio Code - Insiders": return "VSCode Insiders"
        case "GoLand":                        return "GoLand"
        case "IntelliJ IDEA":                 return "IntelliJ"
        case "PyCharm":                       return "PyCharm"
        case "WebStorm":                      return "WebStorm"
        case "Rider":                         return "Rider"
        default:                              return ideName
        }
    }
}
