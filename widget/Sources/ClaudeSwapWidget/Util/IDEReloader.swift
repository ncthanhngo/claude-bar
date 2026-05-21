import Foundation
import AppKit
import ApplicationServices

/// Detects running IDE instances that have the Claude Code extension active,
/// then reloads their windows so they pick up the freshly-swapped credentials.
///
/// Detection source: `~/.claude/ide/{port}.lock`
/// Primary reload: AppleScript keystroke Cmd+Shift+P → "Developer: Reload Window"
/// Fallback (no Accessibility): kill the claude-vscode backend; VSCode restarts it.
enum IDEReloader {

    // MARK: - Accessibility gate

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the native macOS "Allow ClaudeSwapWidget to control your computer?" dialog
    /// and opens System Settings → Accessibility if not yet granted.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as NSDictionary as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Public API

    /// Detect + reload all IDE instances.
    /// If Accessibility is granted: full window reload via AppleScript (cleanest).
    /// If AppleScript fails or no Accessibility: kill extension backend (extension reconnects).
    /// Returns the list of IDE display names acted on.
    @discardableResult
    static func reloadAll() async -> [String] {
        let instances = await detect()
        guard !instances.isEmpty else { return [] }

        var reloaded: [String] = []

        if isAccessibilityGranted {
            // AppleScript window reload — only for VSCode-family IDEs that have a processName.
            // JetBrains IDEs (GoLand, IntelliJ…) don't support this; they use the kill-backend path below.
            for ide in instances where ide.processName != nil {
                if await reload(ide) {
                    reloaded.append(ide.displayName)
                }
            }
        }

        // Kill extension backends for ALL detected IDEs:
        // - VSCode-family: kills remaining open windows not caught by AppleScript
        // - JetBrains (GoLand etc.): kills the Claude extension backend so it reconnects
        //   with the new account credentials on next use
        killExtensionSessions()

        return reloaded.isEmpty ? instances.map { $0.displayName } : reloaded
    }

    /// Kill claude-vscode/IDE backend processes so the extension reconnects
    /// with the new credentials. Does not require Accessibility permission.
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
        let ideName: String        // "Visual Studio Code", "Cursor", "GoLand" …
        let processName: String?   // macOS process name for AppleScript; nil = use kill-backend fallback
        let displayName: String    // Short name shown in notifications
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

    // MARK: - Reload via AppleScript

    @discardableResult
    static func reload(_ ide: IDEInstance) async -> Bool {
        // Put the command on the clipboard BEFORE running AppleScript.
        // Clipboard paste (Cmd+V) bypasses the active IME (e.g. Vietnamese input),
        // avoiding garbled text. We include ">" so it runs as a command, not a file search —
        // Cmd+A after opening the palette would erase the auto-inserted ">".
        let pb = NSPasteboard.general
        let savedClip: [(NSPasteboard.PasteboardType, Data)] = pb.pasteboardItems?.flatMap { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        } ?? []
        pb.clearContents()
        pb.setString(">Developer: Reload Window", forType: .string)

        let script = """
        set prevApp to ""
        try
            tell application "System Events"
                set prevApp to name of first process whose frontmost is true
            end tell
        end try
        tell application "\(ide.ideName)"
            activate
        end tell
        delay 0.8
        tell application "System Events"
            tell process "\(ide.processName)"
                set frontmost to true
                delay 0.3
                keystroke "p" using {command down, shift down}
                delay 0.7
                keystroke "a" using {command down}
                delay 0.1
                keystroke "v" using {command down}
                delay 0.6
                key code 36
            end tell
        end tell
        delay 0.3
        if prevApp is not "" and prevApp is not "\(ide.processName)" then
            try
                tell application prevApp to activate
            end try
        end if
        """
        let ok = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", script]
                let errPipe = Pipe()
                task.standardError = errPipe
                do {
                    try task.launch()
                    task.waitUntilExit()
                    let errOut = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if !errOut.isEmpty {
                        print("[IDEReloader] osascript error (\(ide.displayName)): \(errOut)")
                    }
                    cont.resume(returning: task.terminationStatus == 0)
                } catch {
                    print("[IDEReloader] osascript launch failed: \(error)")
                    cont.resume(returning: false)
                }
            }
        }
        // Restore previous clipboard contents
        DispatchQueue.main.async {
            pb.clearContents()
            for (type, data) in savedClip { pb.setData(data, forType: type) }
        }
        return ok
    }

    /// Run a diagnostic reload and return a human-readable result string.
    static func diagnose() async -> String {
        let ax = isAccessibilityGranted
        let instances = await detect()
        guard !instances.isEmpty else {
            return "AX:\(ax ? "✓" : "✗")  IDE: none detected (check ~/.claude/ide/*.lock)"
        }
        let names = instances.map { $0.displayName }.joined(separator: ", ")
        if !ax {
            killExtensionSessions()
            return "AX:✗  IDE:\(names)  → killed extension backend (grant Accessibility for window reload)"
        }
        var ok: [String] = []
        for ide in instances {
            if await reload(ide) { ok.append(ide.displayName) }
        }
        return ok.isEmpty
            ? "AX:✓  IDE:\(names)  → AppleScript ran but reload failed (check VSCode focus)"
            : "AX:✓  Reloaded: \(ok.joined(separator: ", "))"
    }

    // MARK: - Helpers

    private static func isAlive(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }

    /// Maps Anthropic's ideName to the macOS process name used by System Events.
    /// Returns nil for JetBrains IDEs — they use the kill-backend fallback instead.
    private static func processName(for ideName: String) -> String? {
        switch ideName {
        case "Visual Studio Code": return "Code"
        case "Visual Studio Code - Insiders": return "Code - Insiders"
        case "Cursor": return "Cursor"
        case "Windsurf": return "Windsurf"
        case "Zed": return "Zed"
        default: return nil  // GoLand, IntelliJ, etc. → kill-backend fallback
        }
    }

    private static func shortName(for ideName: String) -> String {
        switch ideName {
        case "Visual Studio Code": return "VSCode"
        case "Visual Studio Code - Insiders": return "VSCode Insiders"
        case "GoLand": return "GoLand"
        case "IntelliJ IDEA": return "IntelliJ"
        case "PyCharm": return "PyCharm"
        case "WebStorm": return "WebStorm"
        case "Rider": return "Rider"
        default: return ideName
        }
    }
}
