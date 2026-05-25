import SwiftUI

// Modal overlay that opens when the footer "Settings" button is tapped.
// Wraps the existing SettingsTab (sidebar + detail panel) inside a card with
// a close button. Same overlay pattern as AddAccountOverlay so the popover
// keeps one consistent modal style.
struct SettingsOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                SettingsTab()
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: 580, maxHeight: 720)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 14, weight: .semibold))
            Text("Settings")
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
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
