import SwiftUI

// Default landing tab. Glanceable: who's active, how much they've used in
// the two windows, what the day/week/month totals look like — and one click
// to switch. No settings, no chart picker.
struct DashboardTab: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var loginCoordinator: LoginCoordinator
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                activeBlock
                summaryBlock
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var activeBlock: some View {
        if let snap = store.snapshot, !snap.accounts.isEmpty {
            if let active = snap.active {
                ActiveAccountCard(active: active, others: snap.accounts.filter { !$0.isActive })
            } else {
                Text("No active account selected.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var summaryBlock: some View {
        if let stats = store.tokenStats {
            sectionTitle("Usage today")
            TokenSummaryStripView(stats: stats)
        } else {
            sectionTitle("Usage today")
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Scanning Claude Code logs…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No accounts yet")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Add your first account") { loginCoordinator.begin() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.top, 4)
    }
}

// Large card representing the currently active account. Differs from the
// AccountListSection row by giving usage bars more vertical room and exposing
// an inline "Switch" menu listing every other available account.
private struct ActiveAccountCard: View {
    let active: AccountViewDTO
    let others: [AccountViewDTO]

    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4).padding(.vertical, 8)
            usageBlock
            if !others.isEmpty {
                Divider().opacity(0.4).padding(.vertical, 8)
                switchRow
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(settings.widgetTheme.activeAccent.opacity(0.45), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(
                initial: active.account.initial,
                seed: active.account.email + (active.account.organizationUuid ?? ""),
                size: 36
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(active.account.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold)).tracking(0.5)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(settings.widgetTheme.activeChipBackground)
                        .clipShape(Capsule())
                }
                Text(active.account.email)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder
    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let usage = active.usage {
                if let w = usage.fiveHour { UsageBar(label: "5h", window: w) }
                else                       { UnavailableBar(label: "5h") }
                if let w = usage.sevenDay  { UsageBar(label: "7d", window: w) }
                else                       { UnavailableBar(label: "7d") }
            } else {
                SkeletonBar(label: "5h")
                SkeletonBar(label: "7d")
            }
        }
    }

    private var switchRow: some View {
        HStack {
            Text("Switch account")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Menu {
                ForEach(others) { acc in
                    Button {
                        Task { await store.swap(to: acc.account.number) }
                    } label: {
                        Label(acc.account.displayName, systemImage: "person.crop.circle")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Choose…")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.accentColor)
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointingHandCursor()
            .help("Pick another account to make active")
        }
    }
}
