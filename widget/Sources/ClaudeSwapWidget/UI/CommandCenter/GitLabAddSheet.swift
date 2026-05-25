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
        // Manual VStack of (label, field) rows instead of SwiftUI `Form` —
        // Form's auto-sized label column clipped longer labels ("Personal
        // Access Token") when the host window was anything under ~560 px
        // wide. Fixed-width label column keeps everything aligned and
        // legible at the FloatingWindow's content size.
        VStack(alignment: .leading, spacing: 14) {
            Text("Add GitLab self-host").font(.headline)
            field(label: "Display name") {
                TextField("e.g. Work GitLab", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            field(label: "Base URL") {
                TextField("https://gitlab.example.com/api/v4", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            field(label: "Note", alignment: .top) {
                TextField("Optional", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            field(label: "Access Token") {
                SecureField("Personal Access Token", text: $pat)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Scopes recommended: `api` (write) or `read_api` (read-only).")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.leading, labelWidth + 12)

            HStack {
                Spacer()
                Button("Cancel") {
                    if let onCancel { onCancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
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
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: .infinity, alignment: .leading)
    }

    private let labelWidth: CGFloat = 110

    @ViewBuilder
    private func field<Content: View>(
        label: String,
        alignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .frame(width: labelWidth, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            content()
                .frame(maxWidth: .infinity)
        }
    }
}
