import SwiftUI
import AppKit

/// Compact list of saved Claude Code accounts with Switch / delete actions.
struct AccountsList: View {
    @ObservedObject var store: UsageStore
    @Binding var showingAddAccount: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if store.accounts.isEmpty { emptyState }
            else                      { rows }
        }
    }

    private var header: some View {
        HStack {
            Text("Accounts").font(.subheadline).bold()
            Spacer()
            Button {
                showingAddAccount = true
            } label: {
                Label("Add", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No saved accounts yet.").font(.caption).foregroundStyle(.secondary)
            Text("Sign into Claude Code with `claude`, then click **Add** to snapshot the login. Repeat for each account.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var rows: some View {
        VStack(spacing: 6) {
            ForEach(store.accounts) { account in
                AccountRow(
                    account: account,
                    isActive: store.config.activeAccountId == account.id,
                    onSwitch: { confirmSwitch(account) },
                    onDelete: { confirmDelete(account) }
                )
            }
        }
    }

    // MARK: - Actions

    private func confirmSwitch(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = "Switch to \"\(account.displayName)\"?"
        alert.informativeText = "Claude Code's Keychain login will be replaced with this account. Restart any running `claude` or VS Code session to pick up the change."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.switchToAccount(id: account.id)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func confirmDelete(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = "Remove \"\(account.displayName)\"?"
        alert.informativeText = "Snapshot is deleted from this app only. The original Claude Code login is untouched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.deleteAccount(id: account.id)
        }
    }
}

// MARK: - Row

private struct AccountRow: View {
    let account: Account
    let isActive: Bool
    let onSwitch: () -> Void
    let onDelete: () -> Void

    private var subtitle: String {
        if isActive, let pct = account.lastSessionPercent {
            return "Active · \(Int(pct.rounded()))% used"
        }
        if isActive {
            return "Active"
        }
        if let pct = account.lastSessionPercent, let observed = account.lastObservedAt {
            return "\(Int(pct.rounded()))% · \(RelativeTime.format(observed))"
        }
        if let switched = account.lastSwitchedAt {
            return "Last used \(RelativeTime.format(switched))"
        }
        return "Never used"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body).fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                if let pct = account.lastSessionPercent {
                    Text("\(Int(pct.rounded()))%")
                        .font(.system(.subheadline, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(UsageColor.forPercent(pct))
                }
            } else {
                Button("Switch", action: onSwitch)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Menu {
                Button("Remove", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive
                      ? Color.green.opacity(0.07)
                      : Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.green.opacity(0.3) : .clear)
        )
    }
}

/// Shared relative-time formatter.
enum RelativeTime {
    static func format(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 0      { return "in the future" }
        if secs < 60     { return "just now" }
        if secs < 3600   { return "\(secs/60)m ago" }
        if secs < 86_400 { return "\(secs/3600)h ago" }
        return "\(secs/86_400)d ago"
    }
}
