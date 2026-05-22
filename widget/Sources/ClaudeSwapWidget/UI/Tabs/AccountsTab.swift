import SwiftUI

// Manage-accounts tab. Sits to the left of the Claude widget on the popover
// bar. The Claude tab also lists accounts (with usage bars) and supports
// per-row rename/remove via context menu — this tab is the dedicated home for
// bulk actions: Add account, verify health, plus a flatter list focused on
// identity (avatar, name, email, web-fallback state) rather than usage.
struct AccountsTab: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var loginCoordinator: LoginCoordinator
    @EnvironmentObject var verifyCoordinator: VerifyCoordinator
    @EnvironmentObject var webFallback: WebFallbackCoordinator
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerRow
                accountList
                Divider()
                AddAccountGuidanceCard()
                Button {
                    loginCoordinator.begin()
                } label: {
                    Label("Add account", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func promptRename(for acc: AccountViewDTO) {
        AccountRenamePrompt.run(for: acc) { newName in
            Task { await store.rename(acc.account.number, to: newName) }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Manage accounts")
                .font(.headline)
            if let snap = store.snapshot {
                Text("\(snap.accounts.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                verifyCoordinator.begin()
            } label: {
                Label("Verify all", systemImage: "checkmark.shield")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Test every account's credentials and web fallback")
            .pointingHandCursor()
        }
    }

    @ViewBuilder
    private var accountList: some View {
        if let snap = store.snapshot, !snap.accounts.isEmpty {
            VStack(spacing: 4) {
                ForEach(snap.accounts) { acc in
                    AccountManageRow(account: acc, onRename: { promptRename(for: acc) })
                }
            }
        } else {
            Text("No accounts added yet. Click \"Add account\" below to add one.")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Compact identity-focused row for the manage tab. No usage bars — those live
// on the Claude tab. Exposes web fallback open/connect, rename, refresh, and
// remove inline (no context-menu).
private struct AccountManageRow: View {
    let account: AccountViewDTO
    let onRename: () -> Void

    @EnvironmentObject var store: AppStore
    @EnvironmentObject var webFallback: WebFallbackCoordinator
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(
                initial: account.account.initial,
                seed: account.account.email + (account.account.organizationUuid ?? ""),
                size: 28
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(account.account.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if account.isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold)).tracking(0.4)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green).clipShape(Capsule())
                    }
                }
                Text(account.account.email)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                webUsageChip
            }
            Spacer(minLength: 4)
            actionButtons
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }

    private var webUsageChip: some View {
        let state = webFallback.state(for: account.account)
        return HStack(spacing: 4) {
            Image(systemName: webUsageIcon(state))
                .font(.system(size: 9))
            Text(state.label)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .foregroundColor(webUsageColor(state))
    }

    private func webUsageIcon(_ state: WebUsageAccountState) -> String {
        switch state {
        case .connected: return "checkmark.icloud"
        case .linked:    return "globe"
        case .fallback:  return "exclamationmark.icloud"
        case .notLinked: return "terminal"
        }
    }

    private func webUsageColor(_ state: WebUsageAccountState) -> Color {
        switch state {
        case .connected: return .green
        case .fallback:  return .orange
        case .linked, .notLinked: return .secondary
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if webFallback.isLinked(account.account) {
                actionButton(icon: "globe", help: "Open web usage profile") {
                    webFallback.open(for: account)
                }
            } else {
                actionButton(icon: "globe.badge.chevron.backward", help: "Connect web usage") {
                    webFallback.open(for: account)
                }
            }
            actionButton(icon: "arrow.clockwise", help: "Force refresh credentials") {
                Task { await store.refreshNow() }
            }
            actionButton(icon: "pencil", help: "Rename") { onRename() }
            if !account.isActive {
                actionButton(icon: "trash", help: "Remove account", role: .destructive) {
                    Task { await store.remove(account.account.number) }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(
        icon: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .pointingHandCursor()
    }
}

