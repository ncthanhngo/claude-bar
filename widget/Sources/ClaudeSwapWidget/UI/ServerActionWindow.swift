import AppKit
import SwiftUI

/// Floating output viewer for a server quick-action (top processes, pending
/// updates, restart result). Runs the async producer, shows a spinner, then the
/// monospaced result. Lives in its own NSWindow — the popover can't host a sheet
/// and collapses on focus loss.
@MainActor
enum ServerActionWindow {
    // Retain each open window until the user closes it; drop it on close so the
    // controllers don't accumulate.
    private static var windows: [FloatingWindow<AnyView>] = []

    static func present(title: String, run: @escaping () async -> String) {
        let fw = FloatingWindow<AnyView>()
        fw.onClose = { windows.removeAll { $0 === fw } }
        windows.append(fw)
        fw.show(title: title, size: NSSize(width: 560, height: 400)) {
            AnyView(ServerActionView(run: run))
        }
    }

    /// Yes/No confirm raised above the menu-bar popover (which otherwise covers
    /// a default-level alert). Returns true on the confirm button.
    static func confirm(title: String, message: String, confirmTitle: String,
                        destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Huỷ")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 3)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct ServerActionView: View {
    let run: () async -> String
    @State private var output: String = ""
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                Spacer()
                ProgressView("Đang chạy trên server…").controlSize(.small)
                Spacer()
            } else {
                ScrollView {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                Divider()
                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Spacer()
                    Button("Chạy lại") { Task { await load() } }
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    private func load() async {
        loading = true
        output = await run()
        loading = false
    }
}
