import AppKit
import Carbon.HIToolbox

/// Multi-shortcut global hotkey registry backed by Carbon's RegisterEventHotKey.
///
/// Used for two named bindings:
///   • `openApp`      → activate the menu bar app (default ⌥Z)
///   • `openBriefing` → show the Daily Briefing window (default ⌥X)
///
/// Carbon avoids the Accessibility permission prompt and works while the app
/// is in the background. Each slot can be re-bound at runtime.
@MainActor
final class HotkeyRegistry {
    static let shared = HotkeyRegistry()

    private struct Slot {
        var ref: EventHotKeyRef?
        var action: () -> Void
    }

    private var slots: [String: Slot] = [:]
    private var ids: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x44425246 // "DBRF"

    init() { installEventHandlerIfNeeded() }

    /// Rebind one slot. Passing `keyCode == 0` clears the binding.
    func register(name: String, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        unregister(name: name)
        guard keyCode != 0 else { return }

        let myID = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: myID)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }

        slots[name] = Slot(ref: ref, action: action)
        ids[myID] = name
    }

    func unregister(name: String) {
        if let slot = slots[name], let ref = slot.ref {
            UnregisterEventHotKey(ref)
        }
        slots.removeValue(forKey: name)
        ids = ids.filter { _, v in v != name }
    }

    fileprivate func dispatch(id: UInt32) {
        guard let name = ids[id], let slot = slots[name] else { return }
        slot.action()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind:  OSType(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, ctx in
            guard let ctx, let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(eventRef,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            let me = Unmanaged<HotkeyRegistry>.fromOpaque(ctx).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async { me.dispatch(id: id) }
            return noErr
        }, 1, &spec, userData, &eventHandler)
    }
}

// MARK: - Default bindings

enum BriefingHotkeySlot {
    static let openApp      = "openApp"
    static let openBriefing = "openBriefing"
}

enum BriefingHotkeyDefaults {
    static let openAppKeyCode:        UInt32 = UInt32(kVK_ANSI_Z)
    static let openAppModifiers:      UInt32 = UInt32(optionKey)
    static let openBriefingKeyCode:   UInt32 = UInt32(kVK_ANSI_X)
    static let openBriefingModifiers: UInt32 = UInt32(optionKey)
}

/// Render a hotkey as the canonical macOS string e.g. "⌥Z", "⌃⌘B".
func hotkeyLabel(keyCode: UInt32, modifiers: UInt32) -> String {
    var s = ""
    if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
    if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
    if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
    s += keyNameForCode(Int(keyCode))
    return s
}

private func keyNameForCode(_ code: Int) -> String {
    switch code {
    case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
    default: return "?"
    }
}
