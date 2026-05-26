import SwiftUI

/// Settings → Accounts. Canonical place to add a Claude Code account from
/// the Settings window. Existing-account management (rename / delete /
/// archive / per-account threshold) still happens in the menu-bar popover
/// — Settings only carries the surfaces that benefit from a wider window
/// and don't repeat the popover's daily-use controls. The list below is a
/// read-only roll-call so the user has the same "what accounts does this
/// Mac know about" picture they get from the popover without having to
/// dismiss Settings to check.
struct AccountsTab: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var loginCoordinator: LoginCoordinator

    var body: some View {
        ScrollView {
            SettingsPage {
                if accounts.isEmpty {
                    // First-run / empty roster: skip the two-group layout
                    // entirely and centre a hero CTA. The user has nothing
                    // to scan — pretending they do (with a list header and
                    // a faint "no accounts yet" caption) wastes the wide
                    // window and hides the action they actually need.
                    emptyHero
                } else {
                    SettingsGroup(
                        "Add account",
                        subtitle: "Run the guided setup to enroll another Claude Code login. The same button also lives on the menu-bar popover header for quick access."
                    ) {
                        Button {
                            loginCoordinator.begin()
                        } label: {
                            Label("Add Claude Code account…", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    SettingsGroup(
                        "Enrolled accounts",
                        subtitle: "Rename, archive, swap, and per-account actions stay on the menu-bar popover where they're one click from the active session."
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(accounts.enumerated()), id: \.element.id) { idx, acc in
                                accountRow(acc)
                                if idx < accounts.count - 1 {
                                    Divider().opacity(0.4)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var accounts: [AccountViewDTO] {
        store.snapshot?.accounts ?? []
    }

    // MARK: - Empty state

    private var emptyHero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 92, height: 92)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(.accentColor)
            }
            VStack(spacing: 6) {
                Text("No accounts yet")
                    .font(.system(size: 16, weight: .semibold))
                Text("Enroll your first Claude Code account to start switching profiles from the menu bar.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                loginCoordinator.begin()
            } label: {
                Label("Add your first account", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 2)
            Text("Each account needs its own `claude /login` session — Claude Bar opens Terminal for you.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Row

    private func accountRow(_ acc: AccountViewDTO) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(acc.isActive ? Color.accentColor : Color.primary.opacity(0.10))
                    .frame(width: 30, height: 30)
                Text(acc.account.initial)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(acc.isActive ? .white : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(acc.account.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if acc.account.displayName != acc.account.email {
                    Text(acc.account.email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if acc.isActive {
                SettingsBadge(text: "ACTIVE", color: .green)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(acc.account.displayName)\(acc.isActive ? ", active" : "")")
    }
}
