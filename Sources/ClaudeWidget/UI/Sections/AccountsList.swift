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
                    pollingEnabled: store.config.multiAccountPollingEnabled,
                    onSwitch: { confirmSwitch(account) },
                    onDelete: { confirmDelete(account) },
                    onRename: { promptRename(account) },
                    onConnectWeb: { confirmConnectWeb(account) },
                    onDisconnectWeb: { store.disconnectWebForAccount(id: account.id) }
                )
            }
        }
    }

    // MARK: - Actions

    private func confirmSwitch(_ account: Account) {
        SwitchAccountAction.confirmAndSwitch(store: store, account: account)
    }

    private func promptRename(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = "Rename account"
        alert.informativeText = "Pick a new label for \"\(account.displayName)\". Only the widget's display name changes — the Claude Code login is untouched."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = account.label
        field.placeholderString = "e.g. work, personal, client-X"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModalAbovePopover() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != account.label else { return }
        store.renameAccount(id: account.id, label: trimmed)
    }

    private func confirmDelete(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = "Remove \"\(account.displayName)\"?"
        alert.informativeText = "Snapshot is deleted from this app only. The original Claude Code login is untouched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModalAbovePopover() == .alertFirstButtonReturn {
            store.deleteAccount(id: account.id)
        }
    }

    /// Explain what "Connect web" does and let the user decide.
    /// On confirm, runs `signInToClaudeAiForAccount` which opens an embedded
    /// browser. The user signs in as the account they want to associate
    /// with this row; we save the captured `sessionKey + orgId` to it.
    private func confirmConnectWeb(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = "Connect claude.ai web session"
        alert.informativeText = """
A Claude login window will open. Sign in as the account you want to associate with "\(account.displayName)".

This is needed so the widget can fetch realtime % for this row in the background. Your current CLI keychain is not touched — only this row's web session is saved.

Note: if you sign in as a different account, this row's polled % will be wrong. Click Cancel if you're unsure which identity to use.
"""
        alert.addButton(withTitle: "Open login window")
        alert.addButton(withTitle: "Skip for now")
        guard alert.runModalAbovePopover() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await store.signInToClaudeAiForAccount(id: account.id)
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }
}

// MARK: - Row

private struct AccountRow: View {
    let account: Account
    let isActive: Bool
    let pollingEnabled: Bool
    let onSwitch: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    let onConnectWeb: () -> Void
    let onDisconnectWeb: () -> Void

    private var hasWebSession: Bool {
        (account.sessionKey?.isEmpty == false) && (account.orgId?.isEmpty == false)
    }

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
            webStatusBadge
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
                Button("Rename…", action: onRename)
                Divider()
                Button(hasWebSession ? "Reconnect web" : "Connect web", action: onConnectWeb)
                if hasWebSession {
                    Button("Disconnect web", action: onDisconnectWeb)
                }
                Divider()
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

    /// Small cloud icon: filled blue if this row has a web session and is
    /// eligible for polling, hollow grey otherwise. Tapping prompts the
    /// user with the connect-web explanation.
    @ViewBuilder
    private var webStatusBadge: some View {
        if hasWebSession {
            Image(systemName: "cloud.fill")
                .font(.caption2)
                .foregroundStyle(pollingEnabled ? .blue : .secondary)
                .help(pollingEnabled
                      ? "Realtime polling enabled for this account."
                      : "Web session saved. Enable 'Track all accounts' in Settings to poll.")
        } else {
            Button(action: onConnectWeb) {
                Image(systemName: "cloud")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help("No web session — usage % can't be polled for this account. Click to connect.")
        }
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
