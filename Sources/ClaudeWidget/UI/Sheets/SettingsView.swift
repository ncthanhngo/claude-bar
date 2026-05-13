import SwiftUI

/// Advanced settings — currently only the JSONL-fallback plan picker.
struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill").foregroundStyle(.tint)
                Text("Settings").font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Fallback plan").font(.subheadline).bold()
                Text("Used when not connected to claude.ai. Sets the assumed 5h token limit so the JSONL-based estimate has a denominator.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: planBinding) {
                    ForEach(Plan.allCases) { plan in
                        Text(plan.displayName).tag(plan)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Limit: \(MenuBarLabel.formatTokens(store.config.effectiveLimit)) tokens / 5h")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400, height: 280)
    }

    private var planBinding: Binding<Plan> {
        Binding(
            get: { store.config.plan },
            set: { store.setPlan($0) }
        )
    }
}
