import SwiftUI
import AppKit

/// First-use repo-link confirmation. Shown when a row references a remote
/// repo (PR / issue) and we want to point Claude at a local checkout.
///
/// Flow:
///   1. Try `csw repomap lookup --origin <url>` for an auto-detected match.
///   2. If hit: render "Use `~/Project/claude-bar` for owner/repo? [Use this
///      / Pick another folder]".
///   3. If miss: render an NSOpenPanel directly (no intermediate sheet).
///
/// Decision is forwarded to onConfirm(localPath) which the caller persists
/// (today: passes path into the session context inject; tomorrow: writes a
/// `linked-repos.json` so subsequent calls auto-resolve).
struct RepoLinkConfirm: View {
    let origin: String
    let suggested: String?
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link.circle.fill").foregroundColor(.accentColor)
                Text("Link repo to Claude session").font(.headline)
            }
            Text("Repo: \(origin)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)

            if let s = suggested, !s.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Auto-detected").font(.caption2).foregroundColor(.secondary)
                    HStack {
                        Image(systemName: "folder.fill").foregroundColor(.blue)
                        Text(s).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
                }
            } else {
                Text("No matching local checkout found.").font(.caption).foregroundColor(.orange)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Pick folder…") { pickFolder() }
                if let s = suggested, !s.isEmpty {
                    Button("Use this") {
                        onConfirm(s)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the local checkout for \(origin)"
        panel.prompt = "Use folder"
        if PopoverModal.runPanel(panel) == .OK, let url = panel.url {
            onConfirm(url.path)
            dismiss()
        }
    }
}
