import SwiftUI

/// Brand + meta strip + actions. Mirrors `.topbar` in the mockup.
struct BriefingTopBarView: View {
    let palette: BriefingPalette
    let dateLabel: String
    let lastGenerated: String
    let nextRun: String
    let isRunning: Bool
    let onRun: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            brand
            metaStrip
            Spacer()
            actionsCluster
        }
        .padding(.bottom, 14)
        .overlay(Divider().background(palette.line), alignment: .bottom)
    }

    @ViewBuilder private var brand: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("đẹp.")
                .font(.system(size: 28, weight: .semibold, design: .serif).italic())
                .foregroundColor(palette.coral)
            Text("DAILY BRIEFING · CLAUDE BAR")
                .font(.system(size: 11))
                .kerning(1.5)
                .foregroundColor(palette.ink3)
        }
    }

    @ViewBuilder private var metaStrip: some View {
        HStack(spacing: 18) {
            metaItem(label: nil, value: dateLabel, bold: true)
            metaItem(label: "cập nhật", value: lastGenerated)
            metaItem(label: "kế tiếp", value: nextRun)
        }
        .font(.system(size: 12))
        .foregroundColor(palette.ink2)
    }

    @ViewBuilder private func metaItem(label: String?, value: String, bold: Bool = false) -> some View {
        HStack(spacing: 4) {
            if let label {
                Text(label).foregroundColor(palette.ink3)
            }
            Text(value)
                .fontWeight(bold ? .semibold : .medium)
                .foregroundColor(palette.ink)
        }
    }

    @ViewBuilder private var actionsCluster: some View {
        HStack(spacing: 10) {
            telegramPill
            ghostButton("Cài đặt", action: onSettings)
            primaryButton(isRunning ? "Đang chạy…" : "Chạy lại", action: onRun)
                .disabled(isRunning)
            closeButton
        }
    }

    @ViewBuilder private var telegramPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(palette.sage)
                .frame(width: 6, height: 6)
            Text("bot Telegram đang nghe")
                .font(.system(size: 11.5))
                .foregroundColor(palette.ink2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(palette.raisedSurface)
        )
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }

    @ViewBuilder private func ghostButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }

    @ViewBuilder private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(palette.paper)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(palette.ink))
    }

    @ViewBuilder private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.ink2)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(palette.raisedSurface))
        .overlay(Circle().stroke(palette.line, lineWidth: 1))
    }
}
