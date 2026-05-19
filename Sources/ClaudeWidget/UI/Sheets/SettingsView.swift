import SwiftUI

/// Widget-wide settings. Currently only controls multi-account realtime
/// polling (toggle + interval picker).
struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @Binding var isPresented: Bool

    @State private var customMinutes: String = ""

    private let presets: [Int] = [60, 300, 900]  // 1m, 5m, 15m

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pollingCard
                if store.config.multiAccountPollingEnabled {
                    statusCard
                }
                SwitchReadinessCard(store: store)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .safeAreaInset(edge: .bottom) {
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.regularMaterial)
        }
        .frame(width: 480, height: 560)
        .onAppear {
            customMinutes = String(store.config.multiAccountPollIntervalSeconds / 60)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill").foregroundStyle(.tint)
            Text("Settings").font(.headline)
        }
    }

    // MARK: - Polling card

    private var pollingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleRow
            if store.config.multiAccountPollingEnabled {
                Divider()
                presetRow
                customRow
                hint
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(store.config.multiAccountPollingEnabled
                      ? Color.blue.opacity(0.06)
                      : Color.secondary.opacity(0.04))
        )
    }

    private var toggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Track all accounts (realtime)").font(.subheadline).bold()
                Text("Fetch usage % for every saved account that has a web session, not just the active one.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { store.config.multiAccountPollingEnabled },
                set: { store.setMultiAccountPolling(enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            Text("Refresh every").font(.caption).foregroundStyle(.secondary)
            ForEach(presets, id: \.self) { sec in
                Button(action: { applyInterval(sec) }) {
                    Text(displayLabel(seconds: sec))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(store.config.multiAccountPollIntervalSeconds == sec ? .accentColor : .secondary)
            }
        }
    }

    private var customRow: some View {
        HStack(spacing: 8) {
            Text("Custom").font(.caption).foregroundStyle(.secondary)
            TextField("minutes", text: $customMinutes)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(width: 80)
                .onSubmit { applyCustom() }
            Text("minutes").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Apply") { applyCustom() }
                .controlSize(.small)
        }
    }

    private var hint: some View {
        Text("Each account adds ~3s to the poll round (Cloudflare + WebKit render). 3 accounts ≈ 10s per refresh. Shorter intervals burn battery and risk rate-limits.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Status card

    private var pollableAccounts: [Account] {
        store.accounts.filter {
            ($0.sessionKey?.isEmpty == false) && ($0.orgId?.isEmpty == false)
        }
    }

    private var unpollableAccounts: [Account] {
        store.accounts.filter {
            ($0.sessionKey?.isEmpty != false) || ($0.orgId?.isEmpty != false)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                Text("Polling status").font(.subheadline).bold()
            }
            Text("\(pollableAccounts.count) of \(store.accounts.count) account\(store.accounts.count == 1 ? "" : "s") ready to poll.")
                .font(.caption).foregroundStyle(.secondary)
            if !unpollableAccounts.isEmpty {
                Text("These accounts need a web session before they can be polled. Open the popover, click the **⋯** menu on each row, then choose **Connect web**:")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(unpollableAccounts) { acc in
                        HStack(spacing: 4) {
                            Image(systemName: "cloud").font(.caption2).foregroundStyle(.orange)
                            Text(acc.displayName).font(.caption2)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.04))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { isPresented = false }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func applyInterval(_ seconds: Int) {
        store.setMultiAccountPollInterval(seconds: seconds)
        customMinutes = String(seconds / 60)
    }

    private func applyCustom() {
        guard let minutes = Int(customMinutes.trimmingCharacters(in: .whitespaces)),
              minutes >= 1 else { return }
        applyInterval(minutes * 60)
    }

    private func displayLabel(seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }
}
