import SwiftUI

// Modal overlay that opens when the footer "Add account" button is tapped.
// Shows the bilingual guidance card the user has always seen, then offers the
// two terminal actions inline so the click-through path is: footer →
// guidance + warning → start. Close button (X) dismisses without starting
// anything.
struct AddAccountOverlay: View {
    @Binding var isPresented: Bool

    @EnvironmentObject private var loginCoordinator: LoginCoordinator

    var body: some View {
        ZStack {
            // Dim layer — tap-to-dismiss matches macOS sheet behaviour without
            // actually using SwiftUI's `.sheet` modifier (which is clipped by
            // MenuBarExtra(.window)).
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        AddAccountGuidanceCard()
                        actions
                    }
                    .padding(18)
                }
                .frame(maxHeight: 540)
            }
            .frame(maxWidth: 540)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
            .padding(.horizontal, 24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 16, weight: .semibold))
            Text("Add a Claude Code account")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .help("Close")
            .pointingHandCursor()
            .accessibilityLabel("Close")
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .pointingHandCursor()
            Button {
                isPresented = false
                loginCoordinator.begin()
            } label: {
                Label("Open Terminal & run claude /login", systemImage: "terminal.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .pointingHandCursor()
            .keyboardShortcut(.defaultAction)
        }
    }
}
