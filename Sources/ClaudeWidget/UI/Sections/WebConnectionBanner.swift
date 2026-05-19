import SwiftUI

/// Disconnected-only CTA. When web is connected, this view collapses to
/// nothing — the active account row's badge + ⋯ menu manages the session,
/// avoiding a duplicate Reconnect/Disconnect surface.
///
/// If there's also a transient `webError`, surface it as a thin red strip
/// even when otherwise connected so users notice fetch failures.
struct WebConnectionBanner: View {
    @ObservedObject var store: UsageStore
    @Binding var showingConnect: Bool

    var body: some View {
        if !store.webConnected {
            disconnectedBanner
        } else if let err = store.webError {
            errorRow(err)
        }
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Số đang ƯỚC LƯỢNG từ JSONL").font(.caption).bold()
                Text("Connect claude.ai để lấy số thật từ Anthropic.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") { showingConnect = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3)))
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
            Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
            Spacer()
            Button { store.fetchWebUsage() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).font(.caption2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.red.opacity(0.08)))
    }
}
