import SwiftUI

/// Capsule chip in the Daily top bar showing the OAuth-active account, its
/// subscription tier, and a colour-coded health dot. Click opens a popover
/// account picker that reuses `AppStore.swap(to:)`.
///
/// Status dot semantics (matches preview HTML):
/// - sage  → healthy (default)
/// - gold  → currently swapping (transient state)
/// - coral → 5h quota >= 80%
struct DailyAccountChip: View {
    @EnvironmentObject private var store: AppStore
    let palette: BriefingPalette

    @State private var pickerOpen = false

    var body: some View {
        Button { pickerOpen.toggle() } label: { chipBody }
            .buttonStyle(.plain)
            .disabled(store.snapshot == nil)
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                DailyAccountPickerPopover(palette: palette) { num in
                    pickerOpen = false
                    Task { await store.swap(to: num) }
                }
                .environmentObject(store)
                .frame(width: 320)
            }
    }

    @ViewBuilder private var chipBody: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: dotColor.opacity(0.35), radius: 0, x: 0, y: 0)
            oauthBadge
            Text(displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(palette.ink)
                .lineLimit(1)
            if let tier = tierLabel {
                Text(tier)
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.ink3)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(palette.ink3)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            Capsule().fill(palette.paper2)
        )
        .overlay(Capsule().stroke(palette.line2, lineWidth: 1))
        .help(helpText)
    }

    @ViewBuilder private var oauthBadge: some View {
        Text("OAuth")
            .font(.system(size: 9.5, weight: .bold))
            .kerning(0.8)
            .foregroundColor(palette.paper)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(palette.moss)
            )
    }

    // MARK: - Derived values

    private var active: AccountViewDTO? { store.snapshot?.active }

    private var displayName: String {
        active?.account.displayName ?? "—"
    }

    private var tierLabel: String? {
        guard let sub = active?.subscriptionType, !sub.isEmpty else { return nil }
        if let pct = active?.usage?.fiveHour?.percentInt {
            return "\(sub) · 5h \(pct)%"
        }
        return sub
    }

    private var dotColor: Color {
        if store.swappingTo != nil { return palette.gold }
        if let pct = active?.usage?.fiveHour?.percentInt, pct >= 80 {
            return palette.coral
        }
        return palette.sage
    }

    private var helpText: String {
        if store.swappingTo != nil { return "Đang chuyển account…" }
        return "OAuth của tài khoản đang active — click để chuyển"
    }
}

/// Compact account picker that reuses the existing AppStore swap flow.
/// Visually aligned with the editorial palette rather than the standard
/// menu bar popover so the Daily window feels coherent.
struct DailyAccountPickerPopover: View {
    @EnvironmentObject private var store: AppStore
    let palette: BriefingPalette
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chuyển tài khoản")
                .font(.system(size: 10.5, weight: .bold))
                .kerning(1.6)
                .foregroundColor(palette.ink3)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(store.snapshot?.accounts ?? []) { acc in
                accountRow(acc)
                Divider().background(palette.line)
            }
            footer
        }
        .background(palette.paper)
    }

    @ViewBuilder private func accountRow(_ acc: AccountViewDTO) -> some View {
        Button { onPick(acc.account.number) } label: {
            HStack(spacing: 11) {
                Circle()
                    .fill(acc.isActive ? palette.sage : palette.line2)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(acc.account.displayName)
                        .font(.system(size: 13, weight: acc.isActive ? .semibold : .regular))
                        .foregroundColor(palette.ink)
                    HStack(spacing: 6) {
                        if let sub = acc.subscriptionType, !sub.isEmpty {
                            Text(sub).font(.system(size: 10.5)).foregroundColor(palette.ink3)
                        }
                        if let pct = acc.usage?.fiveHour?.percentInt {
                            Text("5h \(pct)%").font(.system(size: 10.5)).foregroundColor(palette.ink3)
                        }
                    }
                }
                Spacer()
                if store.swappingTo == acc.account.number {
                    ProgressView().controlSize(.mini)
                } else if acc.isActive {
                    Text("active")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(1.0)
                        .foregroundColor(palette.coral)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(acc.isActive || store.swappingTo != nil)
    }

    @ViewBuilder private var footer: some View {
        Text("OAuth lấy từ tài khoản active · chat sẽ rebind ngay khi đổi")
            .font(.system(size: 10.5))
            .foregroundColor(palette.ink3)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }
}
