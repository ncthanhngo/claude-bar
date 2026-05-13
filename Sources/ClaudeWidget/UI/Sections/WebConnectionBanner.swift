import SwiftUI

/// Top-of-popover status: orange "Connect" banner when not signed in,
/// green checkmark + controls when signed in.
struct WebConnectionBanner: View {
    @ObservedObject var store: UsageStore
    @Binding var showingConnect: Bool

    var body: some View {
        if store.webConnected { connectedRow } else { disconnectedBanner }
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

    private var connectedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
            Text(store.webError ?? "Connected to claude.ai")
                .font(.caption)
                .foregroundStyle(store.webError != nil ? .red : .secondary)
                .lineLimit(1)
            Spacer()
            if store.isFetchingWeb {
                ProgressView().controlSize(.mini).scaleEffect(0.5)
            } else {
                Button { store.fetchWebUsage() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).font(.caption2)
            }
            Menu {
                Button("Reconnect…") { showingConnect = true }
                Button("Disconnect", role: .destructive) { store.disconnectClaudeAi() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
