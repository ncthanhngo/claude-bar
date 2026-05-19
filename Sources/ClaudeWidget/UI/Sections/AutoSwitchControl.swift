import SwiftUI

/// Footer-style toggle + threshold slider for auto-switching accounts.
struct AutoSwitchControl: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(store.config.autoSwitchEnabled ? .blue : .secondary)
                Text("Auto-switch accounts").font(.subheadline)
                Spacer()
                BlueToggle(isOn: Binding(
                    get: { store.config.autoSwitchEnabled },
                    set: { store.setAutoSwitchEnabled($0) }
                ))
            }

            if store.config.autoSwitchEnabled {
                thresholdRow
                hint
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(store.config.autoSwitchEnabled
                      ? Color.blue.opacity(0.06)
                      : Color.secondary.opacity(0.04))
        )
    }

    private var thresholdRow: some View {
        HStack(spacing: 10) {
            Text("Switch at").font(.caption).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { store.config.autoSwitchThresholdPercent },
                    set: { store.setAutoSwitchThreshold($0) }
                ),
                in: 50...99, step: 1
            )
            Text("\(Int(store.config.autoSwitchThresholdPercent))%")
                .font(.system(.caption, design: .rounded))
                .bold().monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var hint: some View {
        Text(store.accounts.count >= 2
             ? "Rotates to the account with the lowest known usage when the active one crosses the threshold. If `claude` is running, the switch is held until you quit it — your session won't be cut mid-turn."
             : "Add at least 2 accounts to enable rotation.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
