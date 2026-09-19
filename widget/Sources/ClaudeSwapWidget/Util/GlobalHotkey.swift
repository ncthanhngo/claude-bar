import AppKit
import Carbon.HIToolbox

/// Multi-shortcut global hotkey registry backed by Carbon's RegisterEventHotKey.
///
/// Used for one named binding:
///   • `openApp` → toggle the menu bar popover (default ⌥Z)
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

enum HotkeySlot {
    static let openApp = "openApp"
}
