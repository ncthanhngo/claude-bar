import SwiftUI

// MARK: - Account list

struct AccountListSection: View {
    @EnvironmentObject var store: AppStore

    // Stats chart sits below this list, so the list shouldn't eat the whole
    // popover. Show 3 accounts in full height, then scroll. ~80pt per row →
    // 3 × 80 + a few px breathing room.
    private static let scrollThreshold = 3
    private static let scrolledHeight: CGFloat = 248

    var body: some View {
        if let snap = store.snapshot, !snap.accounts.isEmpty {
            let sorted = snap.accounts.sorted { $0.isActive && !$1.isActive }
            let needsScroll = sorted.count > Self.scrollThreshold
            let rows = VStack(alignment: .leading, spacing: 3) {
                ForEach(sorted) { acc in
                    AccountRowView(view: acc, onRename: { promptRename(for: acc) })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            if needsScroll {
                ScrollView { rows }.frame(maxHeight: Self.scrolledHeight)
            } else {
                rows
            }
        } else {
            EmptyAccountsView()
        }
    }

    private func promptRename(for acc: AccountViewDTO) {
        AccountRenamePrompt.run(for: acc) { newName in
            Task { await store.rename(acc.account.number, to: newName) }
        }
    }
}

struct EmptyAccountsView: View {
    @EnvironmentObject var loginCoordinator: LoginCoordinator

    var body: some View {
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
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Auto-swap

/// NSSwitch (used by SwiftUI Toggle's `.switch` style) installs its own
/// NSTrackingArea that resets the cursor on every mouse-moved event, so
/// `NSCursor.push()` and `addCursorRect` both lose the race. A custom
/// Button-based switch sidesteps the issue entirely and uses the same
/// `.pointingHandCursor()` path that already works on every other button in
/// the popover.
struct PointingHandSwitch: View {
    @Binding var isOn: Bool
    /// Label exposed to VoiceOver. Caller supplies semantic name (e.g.
    /// "Auto-swap") rather than visual phrasing — the value ("on"/"off")
    /// is announced separately via `accessibilityValue`.
    var accessibilityName: String = "Toggle"

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn ? Color.green : Color.gray.opacity(0.35))
                    .frame(width: 26, height: 15)
                Circle()
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                    .padding(.horizontal, 1)
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct AutoSwapSection: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PointingHandSwitch(isOn: $settings.autoSwapEnabled, accessibilityName: "Auto-swap")
                Text(statusLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)
                if let sess = store.sessions {
                    sessionsBadge(sess)
                }
                Spacer()
            }
            ThresholdSliderView(
                threshold: $settings.thresholdPct,
                currentPct: currentActivePct,
                isEnabled: settings.autoSwapEnabled && isOperational
            )
            if settings.autoSwapEnabled && !isOperational {
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 10)).foregroundColor(UsagePalette.color(for: 70))
                    Text("Paused — no usage data. Will resume when fetch succeeds.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var isOperational: Bool { currentActivePct != nil }

    private var statusLabel: String {
        if !settings.autoSwapEnabled { return "Disabled" }
        return isOperational ? "Enabled" : "Paused"
    }

    private var statusColor: Color {
        if !settings.autoSwapEnabled { return .secondary }
        return isOperational ? .primary : .orange
    }

    private var currentActivePct: Int? {
        store.snapshot?.active?.usage?.fiveHour?.percentInt
    }

    private func sessionsBadge(_ sess: SessionReportDTO) -> some View {
        HStack(spacing: 4) {
            Image(systemName: sess.safeToSwap
                  ? "checkmark.shield.fill"
                  : "exclamationmark.shield.fill")
                .font(.system(size: 10))
            Text(sess.safeToSwap ? "Safe" : "claude busy")
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(sess.safeToSwap
                ? UsagePalette.color(for: 40).opacity(0.12)
                : UsagePalette.color(for: 70).opacity(0.15))
        )
        .foregroundColor(sess.safeToSwap
            ? UsagePalette.color(for: 40)
            : UsagePalette.color(for: 70))
    }
}

