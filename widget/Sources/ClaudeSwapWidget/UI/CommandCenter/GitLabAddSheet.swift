import SwiftUI

/// Sheet that collects a new GitLab self-host instance + its PAT. The PAT
/// is stored in Keychain under `claude-bar-mcp:shared:gitlab:<id>`; the
/// metadata lives in the on-disk gitlab-instances.json registry.
struct GitLabAddSheet: View {
    let onSubmit: (_ name: String, _ baseURL: String, _ note: String, _ pat: String) -> Void
    /// Optional explicit cancel handler. When nil, falls back to the SwiftUI
    /// environment `dismiss` action (works inside `.sheet`); when supplied,
    /// the host owns dismissal (used by the MCP-tab floating window where
    /// `@Environment(\.dismiss)` is a no-op).
    var onCancel: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var note = ""
    @State private var pat = ""

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            baseURL.hasPrefix("https://") &&
            !pat.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add GitLab self-host").font(.headline)
            Form {
                TextField("Display name", text: $name)
                TextField("Base URL (https://…/api/v4)", text: $baseURL)
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                SecureField("Personal Access Token", text: $pat)
                Text("Scopes recommended: `api` (write) or `read_api` (read-only).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    if let onCancel { onCancel() } else { dismiss() }
                }
                Button("Add") {
                    onSubmit(name, baseURL, note, pat)
                    // Host closes the window in the MCP-tab path (onCancel
                    // set); the Diagnostics-card path dismisses via the
                    // sheet's environment action.
                    if onCancel == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
