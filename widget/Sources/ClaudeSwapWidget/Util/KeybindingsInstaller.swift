import Foundation

/// Writes / removes a `workbench.action.reloadWindow` binding in the
/// `keybindings.json` of every detected VSCode-family editor (VSCode,
/// Code Insiders, Cursor, Windsurf, Antigravity).
///
/// Strategy:
/// - Parse JSONC tolerantly (strip `//` and `/* */` comments).
/// - Mark our entries with `"when": "!falseClaudeBarManaged"`. Unknown
///   context key evaluates to false → !false = true → binding always active.
/// - Track last applied state in
///   `~/Library/Application Support/claude-bar/managed-shortcuts.json` so we
///   can clean up cleanly when the user changes or disables the shortcut.
enum KeybindingsInstaller {

    // MARK: - Targets

    struct Target: Hashable {
        let id: String           // stable key for state file
        let displayName: String
        let supportDir: String   // dirname under "~/Library/Application Support/"
    }

    static let allTargets: [Target] = [
        Target(id: "Code",             displayName: "VSCode",          supportDir: "Code"),
        Target(id: "CodeInsiders",     displayName: "VSCode Insiders", supportDir: "Code - Insiders"),
        Target(id: "Cursor",           displayName: "Cursor",          supportDir: "Cursor"),
        Target(id: "Windsurf",         displayName: "Windsurf",        supportDir: "Windsurf"),
        Target(id: "Antigravity",      displayName: "Antigravity",     supportDir: "Antigravity")
    ]

    static let reloadCommand = "workbench.action.reloadWindow"
    static let managedMarker = "!falseClaudeBarManaged"

    // MARK: - Detection

    /// Targets whose `User/` directory exists on disk (= app has run at least
    /// once with this user account).
    static func detectInstalled() -> [Target] {
        allTargets.filter { FileManager.default.fileExists(atPath: userDir(for: $0).path) }
    }

    static func keybindingsFile(for target: Target) -> URL {
        userDir(for: target).appendingPathComponent("keybindings.json")
    }

    private static func userDir(for target: Target) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(target.supportDir)
            .appendingPathComponent("User")
    }

    // MARK: - State file

    struct ManagedState: Codable {
        var lastShortcut: String        // VSCode string ("cmd+ctrl+r")
        var appliedTargets: [String]    // Target.id list
    }

    private static var stateFile: URL {
        let support = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/claude-bar")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("managed-shortcuts.json")
    }

    static func loadState() -> ManagedState? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(ManagedState.self, from: data)
    }

    static func saveState(_ state: ManagedState) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(state) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    static func clearState() {
        try? FileManager.default.removeItem(at: stateFile)
    }

    // MARK: - Public API

    @discardableResult
    static func apply(shortcut: KeyboardShortcut, targets: [Target]? = nil) -> [Target] {
        let installed = (targets ?? detectInstalled())
            .filter { FileManager.default.fileExists(atPath: userDir(for: $0).path) }
        var applied: [Target] = []
        for target in installed {
            if writeBinding(shortcut.vscodeString, to: target) { applied.append(target) }
        }
        saveState(ManagedState(
            lastShortcut: shortcut.vscodeString,
            appliedTargets: applied.map(\.id)
        ))
        return applied
    }

    /// Remove the binding from every target that previously had it (per state
    /// file) PLUS any target currently installed — covers the case where the
    /// state file was deleted but stale entries remain.
    @discardableResult
    static func removeAll() -> [Target] {
        let stateTargets = loadState()?.appliedTargets ?? []
        let union = Set(stateTargets).union(detectInstalled().map(\.id))
        var removed: [Target] = []
        for id in union {
            guard let target = allTargets.first(where: { $0.id == id }),
                  FileManager.default.fileExists(atPath: userDir(for: target).path) else { continue }
            if stripBindings(from: target) { removed.append(target) }
        }
        clearState()
        return removed
    }

    // MARK: - File I/O

    /// Idempotently writes our managed binding. Returns true on success.
    private static func writeBinding(_ key: String, to target: Target) -> Bool {
        let file = keybindingsFile(for: target)
        var entries = readEntries(from: file)
        entries.removeAll(where: isManagedReloadEntry)

        let entry: [String: Any] = [
            "key": key,
            "command": reloadCommand,
            "when": managedMarker
        ]
        entries.append(entry)

        return writeEntries(entries, to: file)
    }

    /// Removes only our managed entries; leaves user-authored bindings alone.
    private static func stripBindings(from target: Target) -> Bool {
        let file = keybindingsFile(for: target)
        guard FileManager.default.fileExists(atPath: file.path) else { return true }
        var entries = readEntries(from: file)
        let before = entries.count
        entries.removeAll(where: isManagedReloadEntry)
        guard entries.count != before else { return true }
        return writeEntries(entries, to: file)
    }

    private static func isManagedReloadEntry(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String) == reloadCommand &&
        (entry["when"] as? String) == managedMarker
    }

    // MARK: - JSONC parsing

    private static func readEntries(from file: URL) -> [[String: Any]] {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let stripped = stripJsonc(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty,
              let data = stripped.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr
    }

    private static func writeEntries(_ entries: [[String: Any]], to file: URL) -> Bool {
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: entries,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Strip `// line` and `/* block */` comments while respecting strings.
    /// Conservative: it's a one-pass scanner, not a full JSONC parser. Good
    /// enough for the small files VSCode writes here.
    static func stripJsonc(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var inString = false
        var escape = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            // Not in a string.
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "/" {
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                    continue
                }
                if n == "*" {
                    i += 2
                    while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") {
                        i += 1
                    }
                    i = min(i + 2, chars.count)
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
