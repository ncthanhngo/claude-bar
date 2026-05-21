import SwiftUI
import AppKit

/// SwiftUI field that captures a single keyboard chord while focused and
/// reports it as a `KeyboardShortcut`. Pure-modifier chords are rejected
/// (must include a non-modifier key).
struct ShortcutRecorderField: View {
    @Binding var shortcut: KeyboardShortcut
    var onChange: ((KeyboardShortcut) -> Void)? = nil

    @State private var recording = false

    var body: some View {
        HStack(spacing: 8) {
            Text(recording ? "Press keys…" : shortcut.displayString)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(recording ? .secondary : .primary)
                .frame(minWidth: 110, alignment: .center)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(recording ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: recording ? 1.5 : 1)
                )
                .onTapGesture { recording.toggle() }

            if recording {
                Button("Cancel") { recording = false }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else {
                Button("Record") { recording = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            Button("Default") {
                shortcut = .defaultShortcut
                onChange?(.defaultShortcut)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .background(
            ShortcutCaptureRepresentable(isActive: $recording) { captured in
                shortcut = captured
                recording = false
                onChange?(captured)
            }
            .frame(width: 0, height: 0)
        )
    }
}

/// Thin NSView wrapper that owns a local key-down monitor while recording.
private struct ShortcutCaptureRepresentable: NSViewRepresentable {
    @Binding var isActive: Bool
    let onCapture: (KeyboardShortcut) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(active: isActive, onCapture: onCapture)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?

        func sync(active: Bool, onCapture: @escaping (KeyboardShortcut) -> Void) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard let s = KeyboardShortcut.from(event: event) else { return event }
                    onCapture(s)
                    return nil  // swallow the chord
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
