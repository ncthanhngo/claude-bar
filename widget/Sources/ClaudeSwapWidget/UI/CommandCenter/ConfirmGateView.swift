import SwiftUI

/// Inline chip-style gate prompt used for Low / Medium / ReadSensitive risks.
/// Renders the resolved summary + countdown progress bar; emits approve or
/// cancel to the coordinator. Two distinct taps required: a primary chip
/// surface (no-op) and the Confirm button — guards against reflex taps.
struct ConfirmGateView: View {
    @ObservedObject var gate: GateCoordinator

    var body: some View {
        if let prompt = gate.pending, !isDestructive(prompt.risk) {
            VStack(alignment: .leading, spacing: 8) {
                header(prompt: prompt)
                Text(prompt.summary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                argLine(prompt.args)
                countdownBar
                HStack(spacing: 8) {
                    Button("Cancel", role: .cancel) { gate.cancel() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Confirm") { gate.approve() }
                        .buttonStyle(.borderedProminent)
                        .tint(accent(prompt.risk))
                }
            }
            .padding(12)
            .background(
                // Solid material so the popover's threshold slider, KPI
                // cards, and chart underneath don't bleed through and
                // collide visually with the gate copy. The earlier
                // .opacity(0.18) tint alone wasn't enough — token-chart
                // labels and slider thumbs showed through, making the
                // overlay text look like it overlapped other widgets.
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(background(prompt.risk).opacity(0.12))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(background(prompt.risk).opacity(0.55), lineWidth: 1)
                )
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Subviews

    private func header(prompt: GatePromptDTO) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(prompt.risk))
                .foregroundColor(background(prompt.risk))
            Text(label(prompt.risk).uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(background(prompt.risk))
            Spacer()
            Text(prompt.tool)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func argLine(_ args: [String: AnyCodable]) -> some View {
        Text(AnyCodable.render(args))
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var countdownBar: some View {
        GeometryReader { geo in
            let total = Double(GateCoordinator.approvalTimeoutSeconds)
            let pct = max(0, min(1, Double(gate.secondsRemaining) / total))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: max(2, geo.size.width * pct), height: 3)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Risk palette

    private func isDestructive(_ r: GateRisk) -> Bool { r == .destructive }

    private func icon(_ r: GateRisk) -> String {
        switch r {
        case .low: return "checkmark.shield"
        case .medium: return "exclamationmark.shield"
        case .destructive: return "exclamationmark.octagon"
        case .readSensitive: return "key.fill"
        }
    }
    private func label(_ r: GateRisk) -> String {
        switch r {
        case .low: return "Confirm"
        case .medium: return "Review"
        case .destructive: return "Destructive"
        case .readSensitive: return "Reveal"
        }
    }
    private func background(_ r: GateRisk) -> Color {
        switch r {
        case .low: return .green
        case .medium: return .blue
        case .destructive: return .red
        case .readSensitive: return .orange
        }
    }
    private func accent(_ r: GateRisk) -> Color {
        switch r {
        case .low: return .green
        case .medium: return .blue
        case .destructive: return .red
        case .readSensitive: return .orange
        }
    }
}
