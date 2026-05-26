import SwiftUI

/// Sheet that collects a new GitLab self-host instance + its PAT. The PAT
/// is stored in Keychain under `claude-bar-mcp:shared:gitlab:<id>`; the
/// metadata lives in the on-disk gitlab-instances.json registry.
struct GitLabAddSheet: View {
    /// Async submit hook. Throwing means the add failed; the sheet
    /// renders the localized error inline and stays open. Returning
    /// normally means success: the sheet shows a brief "Successfully
    /// added" confirmation, then calls `onDismiss` so the host can
    /// close the window. The async style matches `ConnectTokenSheet`
    /// so both flows feel the same to the user — no silent close.
    let onSubmit: (_ name: String, _ baseURL: String, _ note: String, _ pat: String) async throws -> Void
    /// Optional dismiss handler. When nil, falls back to the SwiftUI
    /// environment `dismiss` action (works inside `.sheet`); when
    /// supplied, the host owns dismissal (used by the MCP-tab floating
    /// window where `@Environment(\.dismiss)` is a no-op).
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var note = ""
    @State private var pat = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private func dismissSheet() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

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

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                    Text("Adding…").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting || successMessage != nil)
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isSubmitting || successMessage != nil)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: .infinity, alignment: .leading)
    }

    private let labelWidth: CGFloat = 110

    /// Async submit handler — fires the host's `onSubmit`, shows the
    /// outcome inline, and auto-dismisses 1.2s after success so the
    /// confirmation has time to register. Errors keep the sheet open
    /// so the user can edit the form (typically a malformed base URL
    /// or a bad PAT scope).
    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedPAT = pat.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, trimmedURL.hasPrefix("https://"), !trimmedPAT.isEmpty else { return }
        errorMessage = nil
        isSubmitting = true
        Task {
            do {
                try await onSubmit(trimmedName, trimmedURL, note, trimmedPAT)
                isSubmitting = false
                successMessage = "Successfully added \"\(trimmedName)\". Closing…"
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismissSheet()
            } catch {
                isSubmitting = false
                errorMessage = "Add GitLab instance failed: \(error.localizedDescription)"
            }
        }
    }

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
