import SwiftUI

/// Floating card surfaced when `AppStore.swapError` is non-nil. Lives in the
/// popover ZStack so it overlays the account list without competing for
/// layout space when there's no error.
///
/// Visual design:
///   • Backdrop dim (lets the user know the popover is "modal" without a
///     full sheet, which MenuBarExtra(.window) collapses).
///   • Centered card with a tinted accent stripe sized to the error kind.
///   • Primary CTA: Retry (transient/busy/rate-limited/unknown) or
///     Re-login (needsRelogin).
///   • Secondary: Dismiss (keeps the popover usable; the error fades).
///   • Auto-includes the raw backend message under a disclosure so power
///     users can still read it without polluting the friendly explanation.
struct SwapErrorOverlay: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var loginCoordinator: LoginCoordinator
    @State private var showRaw = false
    @State private var isRetrying = false

    var body: some View {
        if let err = store.swapError {
            ZStack {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }
                    .transition(.opacity)

                card(err)
                    .padding(28)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: err.id)
        }
    }

    @ViewBuilder
    private func card(_ err: SwapError) -> some View {
        VStack(spacing: 0) {
            // Accent stripe
            Rectangle()
                .fill(err.accent)
                .frame(height: 4)

            VStack(alignment: .leading, spacing: 14) {
                header(err)
                explanationBlock(err)
                if showRaw {
                    rawBlock(err)
                }
                rawToggle
                Divider().opacity(0.4)
                actions(err)
            }
            .padding(18)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(err.accent.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.25), radius: 18, y: 8)
        .frame(maxWidth: 420)
    }

    // MARK: - Sections

    private func header(_ err: SwapError) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(err.accent.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: err.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(err.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(err.title.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.6)
                    .foregroundColor(err.accent)
                Text(err.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func explanationBlock(_ err: SwapError) -> some View {
        Text(err.explanation)
            .font(.system(size: 12))
            .foregroundColor(.primary.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
    }

    private func rawBlock(_ err: SwapError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chi tiết kỹ thuật")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(err.rawMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                )
        }
    }

    private var rawToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showRaw.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showRaw ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(showRaw ? "Ẩn chi tiết" : "Xem chi tiết kỹ thuật")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func actions(_ err: SwapError) -> some View {
        HStack(spacing: 10) {
            Button("Đóng", action: dismiss)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)

            Spacer()

            if err.suggestsRelogin {
                Button {
                    dismiss()
                    // Add-account flow doubles as re-login: `claude /login`
                    // overwrites the live slot, csw snapshots it back into
                    // the matching account number (existing entry is updated
                    // in place, not duplicated, because email + org_uuid match).
                    loginCoordinator.begin()
                } label: {
                    Label("Đăng nhập lại", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            } else if err.allowsRetry {
                Button {
                    Task { @MainActor in
                        isRetrying = true
                        await store.retryFailedSwap()
                        isRetrying = false
                    }
                } label: {
                    if isRetrying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Đang thử lại…")
                        }
                    } else {
                        Label("Thử lại", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isRetrying)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Helpers

    private var cardBackground: Color {
        // System surface so the card reads cleanly in both light/dark
        // appearances without depending on the popover's blur material.
        Color(nsColor: .windowBackgroundColor)
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) { store.dismissSwapError() }
    }
}
