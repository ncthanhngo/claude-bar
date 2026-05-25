import SwiftUI

// The "manage" home for accounts. Lists every account with usage bars
// (5h / 7d), hosts the auto-swap controls (toggle + threshold slider), and
// exposes the Add account / Verify all bulk actions.
//
// Auto-swap lives here — not in Settings — because it directly controls how
// the account list above behaves (which account becomes active when the
// active one hits the threshold). Settings is reserved for static
// preferences that do not modify the data on screen.
struct AccountsTab: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var loginCoordinator: LoginCoordinator
    @EnvironmentObject var verifyCoordinator: VerifyCoordinator
    @EnvironmentObject var cloudSync: CloudSyncCoordinator

    @AppStorage("lastAutoSyncSuccessAt") private var lastAutoSyncSuccessAt: Double = 0
    @AppStorage("lastAutoSyncError") private var lastAutoSyncError: String = ""
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                accountsHeader
                AccountListSection()
                sectionTitle("Auto-swap").padding(.top, 10)
                AutoSwapSection()
                Divider().opacity(0.4).padding(.vertical, 10).padding(.horizontal, 14)
                manageBlock
            }
            .padding(.vertical, 6)
        }
    }

    private var accountsHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Accounts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            syncChip
            Spacer()
            if let count = store.snapshot.map({ "\($0.accounts.count)" }) {
                Text(count)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var manageBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    loginCoordinator.begin()
                } label: {
                    Label("Add account", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()

                Button {
                    verifyCoordinator.begin()
                } label: {
                    Label("Verify all", systemImage: "checkmark.shield")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Test every account's credentials and web fallback")
                .pointingHandCursor()

                Spacer()
            }
            AddAccountGuidanceCard()
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }

    // Same iCloud-sync glance chip the old Claude tab carried — kept next to
    // the "Accounts" title because that's the data being synced.
    @ViewBuilder
    private var syncChip: some View {
        let cloudEnabled = iCloudSyncEnabled && cloudSync.status?.exists == true
        let hasSuccess = lastAutoSyncSuccessAt > 0
        let attemptFailed = !lastAutoSyncError.isEmpty
        let now = Date().timeIntervalSince1970
        let successAge = hasSuccess ? now - lastAutoSyncSuccessAt : .infinity
        let isBroken = attemptFailed && successAge > 12 * 3600

        if cloudEnabled && (hasSuccess || attemptFailed) {
            if isBroken {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text("sync failing")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                .help(lastAutoSyncError.isEmpty
                      ? "Auto-sync hasn't succeeded in 12h+ — open Diagnostics to investigate."
                      : "Auto-sync failing: \(lastAutoSyncError)")
            } else if attemptFailed {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(relativeShort(seconds: successAge))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
                .help("Last sync attempt failed. Previous success \(relativeShort(seconds: successAge)) ago.\n\(lastAutoSyncError)")
            } else if hasSuccess {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text(relativeShort(seconds: successAge))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .help("iCloud auto-sync ok — last cycle \(relativeShort(seconds: successAge)) ago.")
            }
        }
    }

    private func relativeShort(seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        if s < 60         { return "now" }
        if s < 60 * 60    { return "\(s / 60)m" }
        if s < 24 * 3600  { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
