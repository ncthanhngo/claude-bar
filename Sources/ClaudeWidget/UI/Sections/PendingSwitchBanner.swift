import SwiftUI

/// Shown when auto-switch threshold is hit but `claude` is still running.
/// Tells the user the switch will fire automatically once they quit Claude Code.
struct PendingSwitchBanner: View {
    let pending: PendingSwitch
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hourglass.circle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pending switch to \(pending.targetAccount.displayName)")
                    .font(.subheadline).bold()
                Text(subtitle)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.orange.opacity(0.35))
        )
    }

    private var subtitle: String {
        let n = pending.blockingPIDs.count
        let plural = n == 1 ? "" : "s"
        return "Waiting for \(n) running `claude` session\(plural) to quit. Switch fires within 15s after the last one exits."
    }
}
