import Foundation
import AppKit
import Carbon.HIToolbox

/// User-configurable reload shortcut, stored as a VSCode-style string
/// (e.g. `"cmd+ctrl+r"`) and exposed as Carbon keyCode + modifier flags for
/// CGEvent posting.
struct KeyboardShortcut: Equatable, Codable {
    /// Modifier bitmask we own. Mirrors VSCode's token names.
    struct Modifiers: OptionSet, Codable {
        let rawValue: Int
        static let cmd     = Modifiers(rawValue: 1 << 0)
        static let shift   = Modifiers(rawValue: 1 << 1)
        static let ctrl    = Modifiers(rawValue: 1 << 2)
        static let alt     = Modifiers(rawValue: 1 << 3)
    }

    /// Carbon HIToolbox virtual keyCode (kVK_*).
    let keyCode: UInt16
    let modifiers: Modifiers
    /// Lowercased plain key token (e.g. `"r"`, `"f1"`, `"space"`).
    let keyToken: String

    // MARK: - Defaults

    static let defaultShortcut = KeyboardShortcut(
        keyCode: UInt16(kVK_ANSI_R),
        modifiers: [.cmd, .ctrl],
        keyToken: "r"
    )

    // MARK: - VSCode string round-trip

    /// VSCode keybindings.json `key` field, e.g. `"ctrl+cmd+r"`. Token order
    /// follows VSCode's own normalization (ctrl, shift, alt, cmd, key).
    var vscodeString: String {
        var parts: [String] = []
        if modifiers.contains(.ctrl)  { parts.append("ctrl") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.alt)   { parts.append("alt") }
        if modifiers.contains(.cmd)   { parts.append("cmd") }
        parts.append(keyToken)
        return parts.joined(separator: "+")
    }

    static func parse(_ raw: String) -> KeyboardShortcut? {
        let parts = raw.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyToken = parts.last, !keyToken.isEmpty else { return nil }
        guard let keyCode = Self.keyCode(for: keyToken) else { return nil }
        var mods: Modifiers = []
        for token in parts.dropLast() {
            switch token {
            case "cmd", "meta", "command":   mods.insert(.cmd)
            case "shift":                    mods.insert(.shift)
            case "ctrl", "control":          mods.insert(.ctrl)
            case "alt", "option", "opt":     mods.insert(.alt)
            default: return nil
            }
        }
        return KeyboardShortcut(keyCode: keyCode, modifiers: mods, keyToken: keyToken)
    }

    // MARK: - Display string

    /// `"⌃⌘R"` — mac-native glyphs, in macOS HIG order (ctrl, alt, shift, cmd).
    var displayString: String {
        var s = ""
        if modifiers.contains(.ctrl)  { s += "⌃" }
        if modifiers.contains(.alt)   { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.cmd)   { s += "⌘" }
        s += keyToken.uppercased()
        return s
    }

    // MARK: - CGEvent translation

    var cgEventFlags: CGEventFlags {
        var f: CGEventFlags = []
        if modifiers.contains(.cmd)   { f.insert(.maskCommand) }
        if modifiers.contains(.shift) { f.insert(.maskShift) }
        if modifiers.contains(.ctrl)  { f.insert(.maskControl) }
        if modifiers.contains(.alt)   { f.insert(.maskAlternate) }
        return f
    }

    // MARK: - NSEvent capture

    /// Build from a key-down NSEvent (used by the recorder field).
    /// Returns nil for events without an alphanumeric/function key payload.
    static func from(event: NSEvent) -> KeyboardShortcut? {
        let mods = event.modifierFlags
        var ours: Modifiers = []
        if mods.contains(.command)  { ours.insert(.cmd) }
        if mods.contains(.shift)    { ours.insert(.shift) }
        if mods.contains(.control)  { ours.insert(.ctrl) }
        if mods.contains(.option)   { ours.insert(.alt) }

        let kc = event.keyCode
        guard let token = Self.token(for: kc) else { return nil }
        return KeyboardShortcut(keyCode: kc, modifiers: ours, keyToken: token)
    }

    // MARK: - keyCode <-> token map

    /// Subset of keys that make sense for an IDE-reload shortcut. Function
    /// rows + alphanumerics cover ~all sensible bindings without dragging in
    /// a 200-entry table.
    private static let tokenToKeyCode: [String: UInt16] = {
        var m: [String: UInt16] = [
            "a": UInt16(kVK_ANSI_A), "b": UInt16(kVK_ANSI_B), "c": UInt16(kVK_ANSI_C),
            "d": UInt16(kVK_ANSI_D), "e": UInt16(kVK_ANSI_E), "f": UInt16(kVK_ANSI_F),
            "g": UInt16(kVK_ANSI_G), "h": UInt16(kVK_ANSI_H), "i": UInt16(kVK_ANSI_I),
            "j": UInt16(kVK_ANSI_J), "k": UInt16(kVK_ANSI_K), "l": UInt16(kVK_ANSI_L),
            "m": UInt16(kVK_ANSI_M), "n": UInt16(kVK_ANSI_N), "o": UInt16(kVK_ANSI_O),
            "p": UInt16(kVK_ANSI_P), "q": UInt16(kVK_ANSI_Q), "r": UInt16(kVK_ANSI_R),
            "s": UInt16(kVK_ANSI_S), "t": UInt16(kVK_ANSI_T), "u": UInt16(kVK_ANSI_U),
            "v": UInt16(kVK_ANSI_V), "w": UInt16(kVK_ANSI_W), "x": UInt16(kVK_ANSI_X),
            "y": UInt16(kVK_ANSI_Y), "z": UInt16(kVK_ANSI_Z),
            "0": UInt16(kVK_ANSI_0), "1": UInt16(kVK_ANSI_1), "2": UInt16(kVK_ANSI_2),
            "3": UInt16(kVK_ANSI_3), "4": UInt16(kVK_ANSI_4), "5": UInt16(kVK_ANSI_5),
            "6": UInt16(kVK_ANSI_6), "7": UInt16(kVK_ANSI_7), "8": UInt16(kVK_ANSI_8),
            "9": UInt16(kVK_ANSI_9),
            "f1": UInt16(kVK_F1), "f2": UInt16(kVK_F2), "f3": UInt16(kVK_F3),
            "f4": UInt16(kVK_F4), "f5": UInt16(kVK_F5), "f6": UInt16(kVK_F6),
            "f7": UInt16(kVK_F7), "f8": UInt16(kVK_F8), "f9": UInt16(kVK_F9),
            "f10": UInt16(kVK_F10), "f11": UInt16(kVK_F11), "f12": UInt16(kVK_F12),
            "space": UInt16(kVK_Space),
            "enter": UInt16(kVK_Return), "return": UInt16(kVK_Return),
            "tab": UInt16(kVK_Tab),
            "escape": UInt16(kVK_Escape), "esc": UInt16(kVK_Escape),
            "`": UInt16(kVK_ANSI_Grave),
            "-": UInt16(kVK_ANSI_Minus), "=": UInt16(kVK_ANSI_Equal),
            "[": UInt16(kVK_ANSI_LeftBracket), "]": UInt16(kVK_ANSI_RightBracket),
            ";": UInt16(kVK_ANSI_Semicolon), "'": UInt16(kVK_ANSI_Quote),
            ",": UInt16(kVK_ANSI_Comma), ".": UInt16(kVK_ANSI_Period), "/": UInt16(kVK_ANSI_Slash),
            "\\": UInt16(kVK_ANSI_Backslash)
        ]
        return m
    }()

    private static let keyCodeToToken: [UInt16: String] = {
        var m: [UInt16: String] = [:]
        for (k, v) in tokenToKeyCode { m[v] = k }
        // Prefer canonical names for ambiguous reverse-lookups.
        m[UInt16(kVK_Return)] = "enter"
        m[UInt16(kVK_Escape)] = "escape"
        return m
    }()

    static func keyCode(for token: String) -> UInt16? { tokenToKeyCode[token.lowercased()] }
    static func token(for keyCode: UInt16) -> String? { keyCodeToToken[keyCode] }
}
