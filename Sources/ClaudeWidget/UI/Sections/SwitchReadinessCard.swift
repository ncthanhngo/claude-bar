import SwiftUI

/// Settings card: per-account verification of switch-readiness.
///
/// Sequentially checks each saved account against the requirements for
/// participating in auto-switch (OAuth blob + valid web session), then
/// renders status + fix instructions per row.
struct SwitchReadinessCard: View {
    @ObservedObject var store: UsageStore

    @State private var results: [UUID: AccountReadinessChecker.Result] = [:]
    @State private var isChecking = false
    @State private var lastCheckedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            description
            if store.accounts.isEmpty {
                emptyState
            } else {
                actionRow
                if !results.isEmpty {
                    Divider()
                    resultsList
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.04))
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.orange)
                Text("No accounts saved yet").font(.caption).bold()
            }
            Text("Verify only checks accounts you've added to the widget. Even if you're signed into `claude` CLI right now, the active login won't appear here until you snapshot it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("→ Close Settings, open the popover, click **Add** → **Snapshot current** to save your current CLI login as the first account.")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.08)))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist").foregroundStyle(.tint)
            Text("Switch readiness").font(.subheadline).bold()
            Spacer()
            if let when = lastCheckedAt {
                Text("Checked \(RelativeTime.format(when))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var description: some View {
        Text("Verify each saved account can be picked by auto-switch. Requires an OAuth blob (CLI swap) + a working claude.ai session (polling).")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actionRow: some View {
        HStack {
            if isChecking {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(action: runCheck) {
                    Label(results.isEmpty ? "Verify all accounts" : "Re-check",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                .disabled(store.accounts.isEmpty)
            }
            Spacer()
            if !results.isEmpty { summaryBadge }
        }
    }

    private var summaryBadge: some View {
        let ready = results.values.filter { $0.status == .ready }.count
        let total = results.count
        return Text("\(ready)/\(total) ready")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(ready == total ? .green : .orange)
    }

    // MARK: - Per-account results

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.accounts) { acc in
                if let r = results[acc.id] {
                    ResultRow(result: r)
                }
            }
        }
    }

    // MARK: - Action

    private func runCheck() {
        guard !isChecking else { return }
        results.removeAll()
        isChecking = true
        let snapshot = store.accounts
        Task {
            await AccountReadinessChecker.check(accounts: snapshot) { r in
                results[r.id] = r
            }
            isChecking = false
            lastCheckedAt = Date()
        }
    }
}

// MARK: - Result row

private struct ResultRow: View {
    let result: AccountReadinessChecker.Result

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName).foregroundStyle(iconColor).font(.caption)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.label).font(.caption).bold()
                Text(result.reason).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = result.fix {
                    Text(fix).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch result.status {
        case .checking:            return "hourglass"
        case .ready:               return "checkmark.circle.fill"
        case .missingOAuthBlob:    return "xmark.octagon.fill"
        case .missingWebSession:   return "cloud.slash"
        case .webSessionExpired:   return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch result.status {
        case .checking:            return .secondary
        case .ready:               return .green
        case .missingOAuthBlob:    return .red
        case .missingWebSession:   return .orange
        case .webSessionExpired:   return .orange
        }
    }
}
