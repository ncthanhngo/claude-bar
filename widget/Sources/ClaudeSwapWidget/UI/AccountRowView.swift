import SwiftUI

struct AccountRowView: View {
    let view: AccountViewDTO
    let onRename: () -> Void

    @EnvironmentObject var store: AppStore
    @EnvironmentObject var webFallback: WebFallbackCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovering = false

    var body: some View {
        Button(action: trySwap) {
            HStack(spacing: 0) {
                // Left accent bar for active account
                if view.isActive {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(settings.widgetTheme.activeAccent)
                        .frame(width: 3)
                        .padding(.vertical, 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    titleLine
                    subtitleLine
                    usageBlock
                }
                .padding(.vertical, 8)
                .padding(.leading, view.isActive ? 9 : 10)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(isHovering && !view.isActive ? Color.primary.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Do NOT use .disabled() — it dims the whole row via SwiftUI opacity.
        // Block interaction manually instead.
        .allowsHitTesting(!view.isActive && store.swappingTo == nil)
        .onHover { hovering in
            isHovering = hovering
            if hovering && !view.isActive { NSCursor.pointingHand.push() }
            if !hovering { NSCursor.pop() }
        }
        .contextMenu { contextMenuBody }
    }

    private var isSwappingThisRow: Bool { store.swappingTo == view.account.number }

    // MARK: - Title line

    private var titleLine: some View {
        HStack(spacing: 8) {
            AvatarView(
                initial: view.account.initial,
                seed: view.account.email + (view.account.organizationUuid ?? ""),
                size: 24
            )
            .overlay(activeDot, alignment: .bottomTrailing)

            Text(view.account.displayName)
                .font(.system(size: 13, weight: view.isActive ? .semibold : .regular))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isSwappingThisRow {
                ProgressView().controlSize(.small)
            } else if view.isActive {
                activeChip
            } else if isHovering {
                Text("Switch →")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
            }

            moreButton.opacity(isHovering ? 1 : 0)
        }
    }

    @ViewBuilder
    private var activeDot: some View {
        if view.isActive {
            Circle()
                .fill(settings.widgetTheme.activeAccent)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
        }
    }

    private var activeChip: some View {
        Text("ACTIVE")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(settings.widgetTheme.activeChipBackground)
            .clipShape(Capsule())
    }

    private var moreButton: some View {
        Menu {
            accountMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Subtitle

    private var subtitleLine: some View {
        HStack(spacing: 4) {
            Text(view.account.email)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if view.account.hasMeaningfulOrg, let org = view.account.organizationName {
                Text("·").foregroundColor(.secondary.opacity(0.5)).font(.caption)
                Text(org)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 32)
    }

    // MARK: - Usage block

    @ViewBuilder
    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if view.credentialState == "needs_login" {
                credentialBadge
            }
            if let usage = view.usage {
                if let w = usage.fiveHour { UsageBar(label: "5h", window: w) }
                if let w = usage.sevenDay  { UsageBar(label: "7d", window: w) }
                if let err = view.error    { errorBadge(err) }
            } else if let err = view.error {
                errorBadge(err)
            } else {
                SkeletonBar(label: "5h")
                SkeletonBar(label: "7d")
            }
        }
        .padding(.leading, 32)
        .padding(.top, 2)
    }

    private var credentialBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 9))
                .foregroundColor(.orange)
            Text("Needs login")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
                .lineLimit(1)
        }
        .help(view.credentialError ?? "Backup credentials cannot refresh.")
    }

    @ViewBuilder
    private func errorBadge(_ msg: String) -> some View {
        let isRateLimit = msg.contains("rate limited") || msg.contains("429")
        let friendly: String = {
            if isRateLimit { return msg.contains("retry in") ? msg : "Anthropic rate-limited · waiting" }
            if msg.contains("no credentials") { return "No credentials" }
            return "Couldn't fetch usage"
        }()
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9)).foregroundColor(.orange)
            Text(friendly)
                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            if isRateLimit {
                Button { webFallback.open() } label: {
                    Text("Use web fallback")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor).underline()
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuBody: some View {
        accountMenuItems
    }

    @ViewBuilder
    private var accountMenuItems: some View {
        Button("Rename…", action: onRename)
        if !view.isActive {
            Button("Switch to this account", action: trySwap)
            Button("Force switch", action: doSwap)
            Divider()
            Button("Remove…", role: .destructive) {
                Task { await store.remove(view.account.number) }
            }
        }
    }

    // MARK: - Swap logic

    private func trySwap() {
        guard !view.isActive else { return }
        let sessions = RunningSession.readAll()
        if sessions.isEmpty {
            doSwap()
            return
        }
        // Show NSAlert directly on the main thread (SwiftUI button actions
        // already run on the main thread — no DispatchQueue wrapper needed).
        let alert = NSAlert()
        alert.messageText = "Claude is running"
        let lines = sessions
            .map { "• \($0.typeLabel): \($0.locationLabel)" }
            .joined(separator: "\n")
        alert.informativeText = "Switching to \(view.account.displayName) will interrupt:\n\(lines)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force switch")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            doSwap()
        }
    }

    private func doSwap() {
        let num = view.account.number
        Task { @MainActor in await store.swap(to: num) }
    }
}
