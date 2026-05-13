import SwiftUI
import AppKit

/// One-button "Sign in with Claude". Opens a hidden WKWebView window pointed
/// at `claude.ai/login`; the `sessionKey` cookie is captured automatically
/// once Anthropic sets it (any IdP — email, Google, Apple, Microsoft).
struct ConnectClaudeAiSheet: View {
    @ObservedObject var store: UsageStore
    @Binding var isPresented: Bool

    @State private var signingIn = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            primaryAction
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(width: 440, height: 280)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.blue)
                Text("Connect to claude.ai").font(.headline)
            }
            Text("Reads realtime usage (session 5h + weekly) from Anthropic. Sign-in runs in an official Claude window — credentials never touch widget code.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var primaryAction: some View {
        Button(action: signIn) {
            HStack {
                if signingIn {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Opening sign-in window…")
                } else {
                    Image(systemName: "globe")
                    Text("Sign in with Claude").bold()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(signingIn)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .disabled(signingIn)
        }
    }

    private func signIn() {
        signingIn = true
        error = nil
        Task {
            do {
                try await store.signInToClaudeAi()
                signingIn = false
                isPresented = false
            } catch {
                self.error = (error as NSError).localizedDescription
                signingIn = false
            }
        }
    }
}
