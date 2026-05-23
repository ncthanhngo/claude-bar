import SwiftUI

/// Modal sheet used for Destructive gates (merge_pr, close_issue, delete).
/// Renders the full resolved args, the 2-sec arming delay on the destructive
/// button, and the countdown. Distinguished from chip-style by red palette +
/// modal presentation.
struct ConfirmGateModal: View {
    @ObservedObject var gate: GateCoordinator
    @State private var armingRemaining: Int = 2

    var body: some View {
        if let prompt = gate.pending, prompt.risk == .destructive {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 20))
                    Text("Destructive action")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Text(prompt.tool)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Divider()
                Text(prompt.summary)
                    .font(.system(size: 14, weight: .medium))
                argsTable(prompt.args)
                countdownBar
                Text("Auto-cancel in \(gate.secondsRemaining)s")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel) { gate.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button(armingRemaining > 0
                           ? "Wait \(armingRemaining)s…"
                           : "Confirm \(prompt.tool)") {
                        gate.approve()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(armingRemaining > 0)
                }
            }
            .padding(20)
            .frame(width: 460)
            .background(Color(NSColor.windowBackgroundColor))
            .onAppear { startArming() }
        }
    }

    private func argsTable(_ args: [String: AnyCodable]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(args.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 8) {
                    Text(key)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(String(describing: args[key]?.value ?? ""))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var countdownBar: some View {
        GeometryReader { geo in
            let pct = max(0, min(1, Double(gate.secondsRemaining) / 30.0))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red)
                    .frame(width: max(2, geo.size.width * pct), height: 4)
            }
        }
        .frame(height: 4)
    }

    private func startArming() {
        armingRemaining = 2
        Task { @MainActor in
            for _ in 0..<2 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if armingRemaining > 0 { armingRemaining -= 1 }
            }
        }
    }
}
