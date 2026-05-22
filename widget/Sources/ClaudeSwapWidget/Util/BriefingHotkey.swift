import AppKit
import Carbon.HIToolbox

/// Lightweight wrapper around `RegisterEventHotKey` for one global hotkey.
///
/// Default binding: ⌃⌥⌘B. User can override via Settings → Briefing → Hotkey
/// (the @AppStorage key + Cocoa key picker live in `BriefingSettingsView`).
///
/// We use Carbon's hot-key API rather than `NSEvent.addGlobalMonitor` so the
/// hotkey works even when the app isn't frontmost and we do NOT require
/// Accessibility permission.
@MainActor
final class BriefingHotkey {
    static let shared = BriefingHotkey()

    /// 4-char OSType "DBRF" (Daily BRieFing).
    private let signature: OSType = 0x44425246

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    /// Register the hotkey. KeyCode = Carbon key code (e.g. `kVK_ANSI_B` = 11).
    /// Modifiers = `cmdKey | shiftKey | controlKey | optionKey` bitmask.
    func register(keyCode: UInt32, modifiers: UInt32, trigger: @escaping () -> Void) {
        unregister()
        onTrigger = trigger

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind:  OSType(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, ctx in
            guard let ctx, let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let me = Unmanaged<BriefingHotkey>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.onTrigger?() }
            return noErr
        }, 1, &eventType, userData, &eventHandler)

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        self.hotKeyRef = ref
    }

    func unregister() {
        if let h = hotKeyRef {
            UnregisterEventHotKey(h)
            hotKeyRef = nil
        }
        if let e = eventHandler {
            RemoveEventHandler(e)
            eventHandler = nil
        }
        onTrigger = nil
    }
}

/// Default binding: ⌃⌥⌘B  (control + option + command + B)
enum BriefingHotkeyDefault {
    static let keyCode: UInt32 = UInt32(kVK_ANSI_B)
    static let modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
}
